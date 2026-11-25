# frozen_string_literal: true

require_relative "../test_helper"
require "fast/completions"
require "kernel/sync"
require_relative "../support/orchestrator_fixtures"
require_relative "../support/mock_completions_server"
require_relative "../support/mock_exa_server"
require_relative "../../lib/kquest/orchestrator/briefing_executor"
require_relative "../../lib/kquest/engine/session_supervisor"

# The BriefingExecutor (I18 Spec Part 1.6): consume the OLDEST enqueued turn
# in one transaction (consumed + consumed_at), append the operator line into
# the session ledger, and drive the engine loop THROUGH the OPERATOR session
# — never a second session (the gate stays with the operator; L13) — with the
# FOUR-tool briefing registration; claims into liveness for the exchange,
# released after; the session NEVER banked by the executor (held-by-row until
# sign-off); after_turn fires after EVERY exchange turn; error shapes ride
# the engine's own laws with the queue row staying `consumed`. Keyless (the
# mock rigs ARE the wires). The blob read-back goes through the executor's
# OWN ledger instance (captured via a contract-factory spy — the MemorySink
# is per-instance in test, Grounds §4.3).
class BriefingExecutorTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @completions = MockCompletionsServer.new.start
    @exa = MockExaServer.new.start
    tenancy = OrchestratorFixtures.mint_tenancy(conn, model_config: {})
    @user_id = tenancy[:user_id]
    @quest_id = tenancy[:quest_id]
    @phase_id = conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "decompose",
                                     round_no: 1, attempt_no: 1, state: "pending")
    conn[:llm_providers].where(name: "briefing-test-provider").delete
    conn[:llm_providers].insert(name: "briefing-test-provider", base_url: @completions.url,
                                api_key_ref: nil, model_id: "briefing-test-model",
                                context_window: 8192, max_tokens: 512, reasoning: false,
                                max_retries: 0)
    conn[:web_providers].where(name: "briefing-exa").delete
    conn[:web_providers].insert(name: "briefing-exa", base_url: @exa.url, api_key_ref: nil,
                                params: Sequel.lit("'{}'::jsonb"))
    conn[:tool_config].where(key: "tools.web_provider").delete
    conn[:tool_config].insert(key: "tools.web_provider", text_value: "briefing-exa",
                              provenance: "test-minted config data")
    conn[:tool_config].where(key: "phase_task_text.briefing").delete
    conn[:tool_config].insert(key: "phase_task_text.briefing",
                              text_value: "Converse with the operator to decompose the question.",
                              provenance: "test-minted config data")
    @session_id = conn[:sessions].insert(user_id: @user_id, quest_id: @quest_id,
                                         phase_id: @phase_id, mode: "interactive",
                                         driver: "operator", model: "briefing-test-provider")
    @supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn)
    # The liveness Set is CLASS-level (one process, one registry — the landed
    # shape): other suite tests hold ids in it. Assert the DELTA (this
    # session's claim released), never global emptiness.
    @liveness_before = @supervisor.live_sessions.dup
    @passes = 0
    @captured_ledger = nil
    @executor = Kquest::Orchestrator::BriefingExecutor.new(
      conn: conn, supervisor: @supervisor, after_turn: -> { @passes += 1 },
      contract_factory: ->(args) do
        @captured_ledger = args.fetch(:ledger)
        Kquest::Orchestrator::BriefingContract.new(**args)
      end
    )
  end

  def teardown
    @completions&.stop
    @exa&.stop
    OrchestratorFixtures.cleanup(conn, user_id: @user_id)
  end

  def session_row
    conn[:sessions].where(id: @session_id).first
  end

  def quest_row
    conn[:quests].where(id: @quest_id).first
  end

  def enqueue(body, seq)
    conn[:briefing_turns].insert(user_id: @user_id, quest_id: @quest_id,
                                 session_id: @session_id, seq: seq, body: body)
  end

  def blob_lines
    bytes = @captured_ledger.sink.read(@captured_ledger.location)
    bytes.to_s.split("\n").filter_map { |l| JSON.parse(l) rescue nil }
  end

  def test_consume_next_flips_the_oldest_enqueued_row_consumed_in_order
    enqueue("second typed", 2)
    enqueue("first typed", 1)

    Sync do
      row = @executor.consume_next!(quest: quest_row, session: session_row)
      refute_nil row
      assert_equal "first typed", row.fetch(:body), "the OLDEST enqueued row (ORDER BY seq)"
      stored = conn[:briefing_turns].where(id: row.fetch(:id)).first
      assert_equal "consumed", stored.fetch(:state)
      refute_nil stored.fetch(:consumed_at)
      assert_equal "enqueued", conn[:briefing_turns].where(seq: 2).get(:state)
    end
  end

  def test_consume_next_returns_nil_when_nothing_is_enqueued
    Sync do
      assert_nil @executor.consume_next!(quest: quest_row, session: session_row)
    end
  end

  def test_exchange_drives_the_operator_session_through_the_engine_loop
    enqueue("stage what you find", 1)
    @completions.script([
      {type: :tool_use, tool_calls: [{id: "bx1", name: "web_search",
                                      arguments: {query: "decay studies"}}]},
      {type: :tool_use, tool_calls: [{id: "bx2", name: "agenda_stage",
                                      arguments: {url: "https://example.test/primer",
                                                  title: "The primer"}}]},
      {type: :tool_use, tool_calls: [{id: "bx3", name: "topic_questions",
                                      arguments: {questions: ["What decays first?"],
                                                  topic: "Momentum decay"}}]},
      {type: :text, content: "staged and recorded — your call"}
    ])
    @exa.script([
      {type: :results, results: [{url: "https://example.test/primer", title: "The primer",
                                  text: "primer body"}]},
      {type: :results, results: [{url: "https://example.test/primer", title: "The primer",
                                  text: "primer body"}]}
    ])

    verdict = Sync do
      row = @executor.consume_next!(quest: quest_row, session: session_row)
      @executor.exchange!(quest: quest_row, session: session_row, row: row)
    end

    assert_equal :completed, verdict

    # the blob location is the session's own CHECK-law location
    key = conn[:sessions].where(id: @session_id).get(:transcript_blob_key)
    assert_equal "sessions/#{@session_id}/transcript.jsonl", key

    # NO second session was ever launched (the gate stays with the operator)
    assert_equal 1, conn[:sessions].where(quest_id: @quest_id).count
    # the executor never banks the operator session (held-by-row until sign-off)
    assert_nil conn[:sessions].where(id: @session_id).get(:ended_at),
               "the operator session is still open after the exchange"

    # the audit: the three scripted tool calls landed, session-attributed, ok
    tools = conn[:tool_calls].where(session_id: @session_id).order(:seq).select_map(:tool)
    assert_equal %w[web_search agenda_stage topic_questions], tools
    assert conn[:tool_calls].where(session_id: @session_id).to_a.all? { |r| r[:ok] }

    # the ingestion door: a role-agenda source, content-addressed
    source = conn[:sources].where(role: "agenda").first
    refute_nil source
    assert_equal "The primer", source.fetch(:title)
    assert source.fetch(:urn).start_with?("kb:src:")

    # the questions carrier: the binding phase's result jsonb
    result = JSON.parse(conn[:phases].where(id: @phase_id).get(Sequel.lit("result::text")))
    assert_equal({"topic_questions" => ["What decays first?"]}, result)
    assert_equal "Momentum decay", conn[:quests].where(id: @quest_id).get(:topic)

    # the spend ledger (D10): usage rows landed for the exchange
    assert_operator conn[:usage_events].where(quest_id: @quest_id).count, :>=, 1

    # the transcript blob carries the operator line + the agent's final
    lines = blob_lines
    assert_equal "operator", lines.first["type"], "the operator line lands FIRST in the blob"
    assert_equal "stage what you find", lines.first["body"]
    assert lines.any? { |l| l["type"] == "final" }, "the agent's final line landed"
    assert lines.any? { |l| l["type"] == "tool_result" && l["tool"] == "agenda_stage" }

    # claims released after the exchange (the DELTA law: this session's
    # claim is gone; other tests' ids in the shared Set are not ours)
    refute_includes @supervisor.live_sessions, @session_id,
                    "the in-process claim released"
    assert_equal @liveness_before, @supervisor.live_sessions

    # after_turn fired after EVERY exchange turn (3 tool turns + the final turn)
    assert_equal 4, @passes, "one after_turn per exchange turn (per-turn SSE seam)"
  end

  def test_error_shape_rides_the_engine_laws_and_the_row_stays_consumed
    enqueue("trigger the loud path", 1)
    @completions.script(Array.new(6, {type: :status, status: 500, message: "provider down"}))

    Sync do
      row = @executor.consume_next!(quest: quest_row, session: session_row)
      error = assert_raises(Kquest::Engine::Error) do
        @executor.exchange!(quest: quest_row, session: session_row, row: row)
      end
      assert_match(/retry cap exhausted|terminal failure/, error.message)

      # the row is the turn's receipt — consumed in every error shape
      assert_equal "consumed", conn[:briefing_turns].where(id: row.fetch(:id)).get(:state)
      # the engine's own law banked the session (the governor's loud path)
      refute_nil conn[:sessions].where(id: @session_id).get(:ended_at),
                 "the governor banked the session (the engine's own law)"
      # the claims released even through the raise (the DELTA law)
      refute_includes @supervisor.live_sessions, @session_id
      assert_equal @liveness_before, @supervisor.live_sessions
    end
  end

  def test_missing_provider_is_the_loud_resolve_refusal
    enqueue("no provider anywhere", 1)
    conn[:llm_providers].delete

    Sync do
      row = @executor.consume_next!(quest: quest_row, session: session_row)
      error = assert_raises(Kquest::Engine::Error) do
        @executor.exchange!(quest: quest_row, session: session_row, row: row)
      end
      assert_includes error.message, "no llm_providers row is available for the briefing exchange"
      assert_equal "consumed", conn[:briefing_turns].where(id: row.fetch(:id)).get(:state)
      refute_includes @supervisor.live_sessions, @session_id,
                      "released even through the loud refusal"
      assert_equal @liveness_before, @supervisor.live_sessions
    end
  end

  def test_four_tool_registration_is_the_exchange_surface
    # A call to a NON-registered tool lands the frozen unknown-tool teaching
    # refusal (the registration IS the restriction) and is audited ok=false.
    enqueue("use a tool you do not have", 1)
    @completions.script([
      {type: :tool_use, tool_calls: [{id: "bx9", name: "node_add",
                                      arguments: {label: "evidence", src: "C1", span: "s"}}]},
      {type: :text, content: "understood — working within the briefing surface"}
    ])

    Sync do
      row = @executor.consume_next!(quest: quest_row, session: session_row)
      verdict = @executor.exchange!(quest: quest_row, session: session_row, row: row)
      assert_equal :completed, verdict

      rows = conn[:tool_calls].where(session_id: @session_id).to_a
      assert_equal 1, rows.size
      assert_equal "node_add", rows.first[:tool], "audited under the name the MODEL called"
      result = rows.first[:result].is_a?(String) ? JSON.parse(rows.first[:result]) : rows.first[:result]
      assert_equal true, result["is_error"],
                   "the interception lands an is_error teaching result (the landed harness law: " \
                   "an unknown call is an in-band refusal, never an exception)"
      lines = blob_lines
      refusal = lines.find { |l| l["type"] == "tool_result" }
      assert_includes refusal["content"], "no such tool: node_add"
      assert_includes refusal["content"], "web_search", "the refusal names the FOUR-tool surface"
      assert_includes refusal["content"], "topic_questions"
    end
  end
end
