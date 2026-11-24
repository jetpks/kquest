# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/pipeline_fixtures"

# The embed body — the iteration's core, one named property per frozen law.
# All keyless: the hermetic mock IS the wire.
class EmbedBodyTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @mock = MockEmbeddingsServer.new.start
  end

  def teardown
    @mock&.stop
    PipelineFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  def vec(marker)
    [marker.to_f] + Array.new(PipelineFixtures::MINILM_DIMS - 1, 0.0)
  end

  def mint_tenancy! = @tenancy = PipelineFixtures.mint_tenancy(conn).tap { @user_id = _1[:user_id] }

  def mint_claim!(text, seq)
    PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @tenancy[:quest_id], seq: seq, text: text)
  end

  def mint_embed_job!(target_kind: "claim", phase_id: nil, batch: 64, cap: 8192, model_status: "active")
    PipelineFixtures.register_test_model(conn, @mock, batch_max_texts: batch, input_max_chars: cap,
                                         status: model_status)
    PipelineFixtures.mint_embed_job(conn, user_id: @user_id, quest_id: @tenancy[:quest_id],
      phase_id: phase_id || @tenancy[:phase_id], kind: "embed", model_id: PipelineFixtures::MINILM_MODEL_ID,
      target_kind: target_kind, idem_key: "embed:#{PipelineFixtures::MINILM_MODEL_ID}:#{target_kind}:quest:#{@tenancy[:quest_id]}")
  end

  def runner(conn: self.conn) = Kquest::Pipeline::Runner.new(conn: conn)

  def vectors_for(job_id)
    conn[PipelineFixtures::MINILM_TABLE.to_sym].where(job_id: job_id).all
  end

  # A stored vector row's first embedding component (pgvector normalizes
  # integral floats: 2.0 prints "2"), parsed back as a number.
  def first_component(row)
    Float(row[:embedding].tr("[]", "").split(",").first)
  end

  # 1 — happy path: vectors + linked spend row (kind, model echo, batch
  # token totals, session/phase/quest chain, embedded_text == canonical_text).
  def test_happy_path_vectors_and_linked_spend_row
    mint_tenancy!
    5.times { |i| mint_claim!("claim text #{i} for the happy path", i + 1) }
    @mock.script([
      {type: :embeddings, vectors: [vec(0), vec(0)], usage: {prompt_tokens: 3, total_tokens: 3}},
      {type: :embeddings, vectors: [vec(0), vec(0)], usage: {prompt_tokens: 5, total_tokens: 5}},
      {type: :embeddings, vectors: [vec(0)], usage: {prompt_tokens: 7, total_tokens: 7}}
    ])
    job_id = mint_embed_job!(batch: 2)

    assert_equal :complete, runner.call(job_id: job_id)

    rows = vectors_for(job_id)
    assert_equal 5, rows.size
    rows.each { |r| assert_equal "active", r[:model_status] }
    texts = conn[:claims].where(quest_id: @tenancy[:quest_id]).order(:quest_seq).select_map(:canonical_text)
    stored = rows.sort_by { |r| conn[:claims].where(id: r[:claim_id]).first[:quest_seq] }
    assert_equal texts, stored.map { |r| r[:embedded_text] } # registry order == wire order

    job = conn[:embed_jobs].where(id: job_id).first
    spend = conn[:usage_events].where(id: job[:usage_event_id]).first
    refute_nil spend
    assert_equal "embedding", spend[:kind]
    assert_equal "mock-embed-384", spend[:model] # the registry wire_name, as an audit ECHO
    assert_equal 15, spend[:input_tokens] # the batch totals: 3 + 5 + 7
    assert_equal 0, spend[:output_tokens]
    assert_nil spend[:cost_usd] # the gem surfaces TOKENS only
    assert_equal @user_id, spend[:user_id]
    assert_equal @tenancy[:quest_id], spend[:quest_id]
    assert_equal @tenancy[:phase_id], spend[:phase_id]
    assert_equal @tenancy[:session_id], spend[:session_id] # the D10 chain, total
  end

  # 2 — the wire reply is zipped by the entry's INDEX, never its array
  # position (the gem's wire-order contract; the mock's index_order scrambler).
  def test_wire_reply_zipped_by_index_not_array_position
    mint_tenancy!
    3.times { |i| mint_claim!("index zip claim #{i}", i + 1) }
    # index_order [2,0,1] delivers data = [{v2,idx2},{v0,idx0},{v1,idx1}] —
    # the array is scrambled, each entry's INDEX value rides with it. A
    # position zip would hand claim 0 the marker-2 vector.
    @mock.script([{type: :embeddings, vectors: [vec(0), vec(1), vec(2)],
      usage: {prompt_tokens: 9, total_tokens: 9}, index_order: [2, 0, 1]}])
    job_id = mint_embed_job!(batch: 10)

    assert_equal :complete, runner.call(job_id: job_id)

    # v(marker k) belongs to the entry carrying index k, i.e. to the k-th
    # claim text — a position zip would give claim 0 the marker-2 vector.
    vectors_for(job_id).each do |row|
      seq = conn[:claims].where(id: row[:claim_id]).first[:quest_seq] - 1
      assert_equal seq.to_f, first_component(row),
        "claim #{seq}'s vector is the one that carried index #{seq} on the wire"
    end
  end

  # 3 — batch slicing by the registry row's batch_max_texts: [2, 2, 1].
  def test_batch_slicing_by_batch_max_texts
    mint_tenancy!
    5.times { |i| mint_claim!("slicing claim #{i}", i + 1) }
    @mock.script(Array.new(3) do |b|
      {type: :embeddings, vectors: Array.new(b == 2 ? 1 : 2) { vec(0) }, usage: {prompt_tokens: 1, total_tokens: 1}}
    end)
    job_id = mint_embed_job!(batch: 2)

    assert_equal :complete, runner.call(job_id: job_id)

    requests = @mock.captured_requests # DRAIN once
    assert_equal [2, 2, 1], requests.map { |r| r["input"].size }
  end

  # 4 — over-length REFUSED before ANY wire call (never truncated).
  def test_over_length_refused_before_any_wire_call
    mint_tenancy!
    long = mint_claim!("this single claim text is far too long for the tiny cap below", 1)
    mint_claim!("short one", 2)
    job_id = mint_embed_job!(batch: 10, cap: 20)

    assert_equal :failed, runner.call(job_id: job_id)

    assert_equal 0, @mock.captured_requests.size, "refusal precedes every wire call"
    job = conn[:embed_jobs].where(id: job_id).first
    assert_equal "failed", job[:state]
    assert_match(/claim/, job[:error_note])
    assert_match(long.to_s, job[:error_note]) # the OFFENDING target id
    assert_match(/20/, job[:error_note]) # the cap
    assert_nil job[:usage_event_id]
    assert_equal 0, conn[:usage_events].where(user_id: @user_id).count
  end

  # 5 — rerun of a complete scope is a NOOP (no new wire call).
  def test_rerun_of_complete_is_a_noop
    mint_tenancy!
    2.times { |i| mint_claim!("rerun claim #{i}", i + 1) }
    @mock.script([{type: :embeddings, vectors: [vec(0), vec(0)], usage: {prompt_tokens: 4, total_tokens: 4}}])
    job_id = mint_embed_job!(batch: 10)
    assert_equal :complete, runner.call(job_id: job_id)
    assert_equal 2, vectors_for(job_id).size
    @mock.captured_requests # DRAIN the first run's capture

    assert_equal :noop, runner.call(job_id: job_id)

    assert_empty @mock.captured_requests # no new wire call
    assert_equal 2, vectors_for(job_id).size
    assert_equal 1, conn[:usage_events].where(user_id: @user_id).count
  end

  # 6 — kill-mid-job resumes from the durable cursor: fork + SIGKILL after
  # batch 1's commit (batches [2,1] — the child dies mid batch 2's wire
  # call); the row stays running at the cursor with batch 1's vectors
  # durable; the resume makes exactly ONE new wire call — no re-embed.
  def test_kill_mid_job_resumes_from_the_durable_cursor
    mint_tenancy!
    texts = (1..3).map { |i| "kill resume claim #{i}" }
    texts.each_with_index { |t, i| mint_claim!(t, i + 1) }
    @mock.script([
      {type: :embeddings, vectors: [vec(0), vec(0)], usage: {prompt_tokens: 2, total_tokens: 2}},
      {type: :never_respond} # batch 2 blocks forever; the parent kills the child
    ])
    job_id = mint_embed_job!(batch: 2)

    child_pid = fork do
      begin
        # Fork-safety: a FRESH Sequel connection, never the parent's.
        child_conn = Sequel.connect(ENV.fetch("DATABASE_URL"))
        runner(conn: child_conn).call(job_id: job_id)
        child_conn.disconnect
      rescue StandardError => e
        warn "kill-test child: #{e.class}: #{e.message}"
      end
      exit! 0 # never run minitest's at_exit in the child
    end

    begin
      deadline = Time.now + 15
      row = nil
      loop do
        row = conn[:embed_jobs].where(id: job_id).first
        break if row[:done_items] == 2 || Time.now > deadline

        sleep 0.05
      end
    ensure
      begin
        Process.kill("KILL", child_pid)
        Process.wait(child_pid)
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end
    end

    # The killed child's wire calls (batch 1 + the blocked batch 2) drained.
    assert_equal 2, @mock.captured_requests.size

    # Mid-state: running at the cursor, batch 1's vectors durable.
    row = conn[:embed_jobs].where(id: job_id).first
    assert_equal "running", row[:state]
    assert_equal 2, row[:done_items]
    assert_equal 2, vectors_for(job_id).size

    # Resume from the row ALONE: exactly one new wire call — batch 2 only,
    # batch 1's texts never re-embedded.
    @mock.script([{type: :embeddings, vectors: [vec(0)], usage: {prompt_tokens: 1, total_tokens: 1}}])
    assert_equal :complete, runner.call(job_id: job_id)

    requests = @mock.captured_requests
    assert_equal 1, requests.size, "the resume re-embeds NOTHING — one wire call for the last batch"
    assert_equal [texts[2]], requests[0]["input"]

    row = conn[:embed_jobs].where(id: job_id).first
    assert_equal "complete", row[:state]
    assert_equal 3, row[:done_items]
    assert_equal 3, row[:total_items]
    assert_equal 3, vectors_for(job_id).size
    assert_operator conn[:usage_events].where(id: row[:usage_event_id]).first[:input_tokens], :>=, 1
  end

  # 7 — J-SPEND both directions over the WHOLE ledger (SQL, not fixtures).
  def test_jspend_both_directions_over_the_whole_ledger
    mint_tenancy!
    2.times { |i| mint_claim!("ledger claim #{i}", i + 1) }
    @mock.script([{type: :embeddings, vectors: [vec(0), vec(0)], usage: {prompt_tokens: 6, total_tokens: 6}}])
    job_id = mint_embed_job!(batch: 10)
    assert_equal :complete, runner.call(job_id: job_id)

    # →: every completed embed job links a kind-matching usage row.
    orphans = conn[:embed_jobs]
      .where(kind: "embed", state: "complete")
      .where(Sequel[:usage_event_id] => nil)
      .count
    wrong_kind = conn[:embed_jobs].join(:usage_events, id: :usage_event_id)
      .where(Sequel[:embed_jobs][:kind] => "embed", Sequel[:embed_jobs][:state] => "complete")
      .exclude(Sequel[:usage_events][:kind] => "embedding")
      .count
    assert_equal 0, orphans, "every completed embed job links a usage row"
    assert_equal 0, wrong_kind, "the linked usage row is always kind=embedding"

    # ←: every embedding usage row links back from a completed embed job.
    back = conn[:usage_events].where(kind: "embedding")
      .where(Sequel[:usage_events][:id] => conn[:embed_jobs]
        .where(kind: "embed", state: "complete").select(:usage_event_id)).count
    total_embedding = conn[:usage_events].where(kind: "embedding").count
    assert_equal total_embedding, back, "every embedding usage row links back from a completed embed job"

    # usage_event_id appears on NOTHING else (non-complete or non-embed).
    stray = conn[:embed_jobs].where(Sequel[:usage_event_id] !~ nil)
      .exclude(kind: "embed", state: "complete").count
    assert_equal 0, stray
  end

  # 8 — retired registry rows refused (history survives, new work does not).
  def test_retired_model_refused
    mint_tenancy!
    mint_claim!("retired claim", 1)
    job_id = mint_embed_job!(model_status: "retired")

    assert_equal :failed, runner.call(job_id: job_id)
    assert_empty @mock.captured_requests
    assert_match(/retired/, conn[:embed_jobs].where(id: job_id).first[:error_note])
    assert_equal 0, conn[:usage_events].where(user_id: @user_id).count
  end

  # 9 — missing phase/session fails loudly at completion (no orphan spend).
  def test_missing_phase_session_fails_loudly_at_completion
    mint_tenancy!
    2.times { |i| mint_claim!("orphan spend claim #{i}", i + 1) }
    # A real phase with NO session: the D10 chain must resolve through it.
    bare_phase = conn[:phases].insert(user_id: @user_id, quest_id: @tenancy[:quest_id], kind: "descent")
    @mock.script([{type: :embeddings, vectors: [vec(0), vec(0)], usage: {prompt_tokens: 5, total_tokens: 5}}])
    job_id = mint_embed_job!(phase_id: bare_phase)

    assert_equal :failed, runner.call(job_id: job_id)

    job = conn[:embed_jobs].where(id: job_id).first
    assert_equal "failed", job[:state]
    assert_match(/session/, job[:error_note])
    assert_equal 0, conn[:usage_events].where(user_id: @user_id).count, "no orphan spend, ever"
    assert_equal 2, vectors_for(job_id).size # the work is durable; the cursor is kept
    assert_equal 2, job[:done_items]
  end

  # 10 — zero-target completes with a ZERO-token spend row (no wire calls).
  def test_zero_target_completes_with_zero_token_spend_row
    mint_tenancy!
    job_id = mint_embed_job! # a quest with no claims: zero targets

    assert_equal :complete, runner.call(job_id: job_id)

    assert_empty @mock.captured_requests
    job = conn[:embed_jobs].where(id: job_id).first
    spend = conn[:usage_events].where(id: job[:usage_event_id]).first
    refute_nil spend, "the call is still an event (FM-25's posture)"
    assert_equal 0, spend[:input_tokens]
    assert_equal "embedding", spend[:kind]
    assert_equal @tenancy[:session_id], spend[:session_id]
  end

  # 11 — the multi-frame live-wire reply parses end-to-end (the :multi_frame
  # rig reproduces the live framing physics hermetically; RED through gem
  # 0.1.0 by mutation, GREEN through the pinned 0.1.1 — the framing-seam
  # class as regression law).
  def test_multi_frame_live_wire_reply_parses_end_to_end
    mint_tenancy!
    2.times { |i| mint_claim!("framed claim #{i}", i + 1) }
    body = JSON.generate({
      "object" => "list",
      "data" => [
        {"object" => "embedding", "embedding" => vec(0), "index" => 0},
        {"object" => "embedding", "embedding" => vec(1), "index" => 1}
      ],
      "model" => "mock-model",
      "usage" => {"prompt_tokens" => 9, "total_tokens" => 9}
    })
    # slice 1024: the 0.1.0 failure class at byte 1025 (live: byte 8193).
    @mock.script([{type: :multi_frame, body: body, slice: 1024, pause: 0.01}])
    job_id = mint_embed_job!(batch: 10)

    assert_equal :complete, runner.call(job_id: job_id)

    rows = vectors_for(job_id)
    assert_equal 2, rows.size
    texts = conn[:claims].where(quest_id: @tenancy[:quest_id]).order(:quest_seq).select_map(:canonical_text)
    stored = rows.sort_by { |r| conn[:claims].where(id: r[:claim_id]).first[:quest_seq] }
    assert_equal texts, stored.map { |r| r[:embedded_text] }
    assert_equal 0.0, first_component(stored[0])
    assert_equal 1.0, first_component(stored[1])
    assert_equal 9, conn[:usage_events].where(id: conn[:embed_jobs].where(id: job_id).first[:usage_event_id])
      .first[:input_tokens]
  end

  # 12 — the multi-batch durable cursor ACCUMULATES (judgment F-1): a loud
  # failure after batch 2's commit leaves the cursor exactly at the
  # targets embedded (4 with 4 vectors durable), never the once-loaded
  # row hash's stale arithmetic (2). I03 §6: the cursor is exactly
  # "targets embedded"; L7: a resume re-embeds nothing.
  def test_multi_batch_failure_keeps_the_cursor_exactly_at_targets_embedded
    mint_tenancy!
    5.times { |i| mint_claim!("cursor accumulation claim #{i}", i + 1) }
    # Batches [2,2,1]; batch 3's reply carries a DUPLICATE index — a loud
    # write_vectors! refusal AFTER batch 2's commit, before batch 3's.
    dup_reply = JSON.generate({
      "object" => "list",
      "data" => [
        {"object" => "embedding", "embedding" => vec(0), "index" => 0},
        {"object" => "embedding", "embedding" => vec(0), "index" => 0}
      ],
      "model" => "mock-model",
      "usage" => {"prompt_tokens" => 1, "total_tokens" => 1}
    })
    @mock.script([
      {type: :embeddings, vectors: [vec(0), vec(0)], usage: {prompt_tokens: 2, total_tokens: 2}},
      {type: :embeddings, vectors: [vec(0), vec(0)], usage: {prompt_tokens: 2, total_tokens: 2}},
      {type: :raw, body: dup_reply}
    ])
    job_id = mint_embed_job!(batch: 2)

    assert_equal :failed, runner.call(job_id: job_id)

    job = conn[:embed_jobs].where(id: job_id).first
    assert_equal "failed", job[:state]
    assert_equal 5, job[:total_items]
    assert_equal 4, job[:done_items], "the durable cursor is CUMULATIVE across batches — exactly the targets embedded"
    assert_equal 4, vectors_for(job_id).size, "4 vectors durable; the ledger never lies"
    assert_match(/index/, job[:error_note])
    assert_equal 3, @mock.captured_requests.size # all three batches reached the wire
  end

  # 13 — chunk-family enumeration is QUEST-NARROWED (judgment F-2, driver
  # ruling 2026-11-24): a source staged to TWO quests is enumerated once
  # per quest's job (no duplicate embed work, no inflated total_items), a
  # source staged only to the user's OTHER quest never leaks in, and the
  # spend row lands on the job's quest (DR-06 ruling A: per-quest
  # attribution — one job per (strategy, quest)).
  def test_chunk_family_enumeration_is_quest_narrowed
    mint_tenancy!
    quest_a = @tenancy[:quest_id]
    quest_b = conn[:quests].insert(user_id: @user_id, topic: "Quest B shares a source with quest A",
      web_call_budget: 16, token_budget: 1_000_000, spend_budget_usd: 1.0)
    phase_b = conn[:phases].insert(user_id: @user_id, quest_id: quest_b, kind: "descent")
    PipelineFixtures.mint_session(conn, user_id: @user_id, quest_id: quest_b, phase_id: phase_b)
    strategy_id = PipelineFixtures.mint_strategy(conn, name: "para-800")

    # One source, two quests: the second fetch rides the D3 dedup path and
    # still registers quest B's membership on the SAME source.
    shared_snapshot = "first shared paragraph. second shared paragraph."
    shared = Kquest::Pipeline::FetchBody.call(user_id: @user_id,
      url: "https://fixture.example/shared", title: "Shared fixture source", role: "citable",
      snapshot_text: shared_snapshot, raw_body: "raw:shared", quest_id: quest_a,
      phase_id: @tenancy[:phase_id], conn: conn)
    again = Kquest::Pipeline::FetchBody.call(user_id: @user_id,
      url: "https://fixture.example/shared", title: "Shared fixture source", role: "citable",
      snapshot_text: shared_snapshot, raw_body: "raw:shared", quest_id: quest_b,
      phase_id: phase_b, conn: conn)
    assert_equal shared[:source_id], again[:source_id]
    assert_equal false, again[:created]
    only_b = Kquest::Pipeline::FetchBody.call(user_id: @user_id,
      url: "https://fixture.example/only-b", title: "Quest B only fixture source", role: "citable",
      snapshot_text: "quest B only paragraph.", raw_body: "raw:only-b", quest_id: quest_b,
      phase_id: phase_b, conn: conn)

    # Chunks for both sources (offsets coherent with the snapshots: the
    # I01 verbatim-substring CHECKs bite otherwise).
    anchor = conn[:sources].where(id: shared[:source_id]).first[:anchorable]
    shared_texts = ["first shared paragraph.", "second shared paragraph."]
    shared_starts = [0, 24]
    shared_texts.each_with_index do |text, i|
      conn[:chunks].insert(source_id: shared[:source_id], user_id: @user_id,
        strategy_id: strategy_id, ordinal: i + 1, text: text,
        char_start: shared_starts[i], char_end: shared_starts[i] + text.length,
        snapshot_char_count: shared_snapshot.length, source_anchorable: anchor)
    end
    conn[:chunks].insert(source_id: only_b[:source_id], user_id: @user_id,
      strategy_id: strategy_id, ordinal: 1, text: "quest B only paragraph.",
      char_start: 0, char_end: "quest B only paragraph.".length,
      snapshot_char_count: "quest B only paragraph.".length, source_anchorable: anchor)

    # Quest A's job: the shared source's chunks ONCE; quest B's own source
    # never leaks in; spend attributed to quest A (DR-06 ruling A).
    PipelineFixtures.register_test_model(conn, @mock, batch_max_texts: 64)
    job_a = PipelineFixtures.mint_embed_job(conn, user_id: @user_id, quest_id: quest_a,
      phase_id: @tenancy[:phase_id], kind: "embed", model_id: PipelineFixtures::MINILM_MODEL_ID,
      target_kind: "chunk", strategy_id: strategy_id,
      idem_key: "embed:#{PipelineFixtures::MINILM_MODEL_ID}:chunk:para-800:quest:#{quest_a}")
    @mock.script([{type: :embeddings, vectors: [vec(0), vec(0)],
      usage: {prompt_tokens: 2, total_tokens: 2}}])
    assert_equal :complete, runner.call(job_id: job_a)

    requests = @mock.captured_requests
    assert_equal 1, requests.size
    assert_equal shared_texts, requests[0]["input"],
      "each shared chunk exactly ONCE — no duplicate embed work, no other-quest chunks"
    row_a = conn[:embed_jobs].where(id: job_a).first
    assert_equal 2, row_a[:total_items]
    assert_equal 2, row_a[:done_items]
    assert_equal 2, vectors_for(job_a).size
    spend_a = conn[:usage_events].where(id: row_a[:usage_event_id]).first
    assert_equal quest_a, spend_a[:quest_id], "DR-06 ruling A: the spend lands on the job's quest"

    # Quest B's job embeds the shared chunks for ITS quest plus its own
    # source — the narrowing follows the JOB's quest; it is not a dedup.
    job_b = PipelineFixtures.mint_embed_job(conn, user_id: @user_id, quest_id: quest_b,
      phase_id: phase_b, kind: "embed", model_id: PipelineFixtures::MINILM_MODEL_ID,
      target_kind: "chunk", strategy_id: strategy_id,
      idem_key: "embed:#{PipelineFixtures::MINILM_MODEL_ID}:chunk:para-800:quest:#{quest_b}")
    @mock.script([{type: :embeddings, vectors: [vec(0), vec(0), vec(0)],
      usage: {prompt_tokens: 3, total_tokens: 3}}])
    assert_equal :complete, runner.call(job_id: job_b)

    requests = @mock.captured_requests
    assert_equal 1, requests.size
    assert_equal ["quest B only paragraph.", *shared_texts].sort, requests[0]["input"].sort
    row_b = conn[:embed_jobs].where(id: job_b).first
    assert_equal 3, row_b[:total_items]
    spend_b = conn[:usage_events].where(id: row_b[:usage_event_id]).first
    assert_equal quest_b, spend_b[:quest_id]
  end
end
