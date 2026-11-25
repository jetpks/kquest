# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/pipeline_fixtures"

# The shared tool-test rig (the per-tool fixture tests include it). The
# frozen fixture files are the BYTE SOURCE — this rig parses them at runtime
# and never carries a copied text.
module ToolRig
  FIXTURES_DIR = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures", __dir__)

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def teardown
    # The tool tests create evidence/derivations/report rows the pipeline
    # sweep predates — clear them (reverse-FK) before the shared cleanup.
    if @user_id
      conn[:report_citations].where(user_id: @user_id).delete
      conn[:report_versions].where(user_id: @user_id).delete
      conn[:evidence_edges].where(user_id: @user_id).delete
      conn[:evidence].where(user_id: @user_id).delete
      conn[:claim_derivations].where(user_id: @user_id).delete
    end
    PipelineFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  # The session tenancy (the same mint the pipeline suite uses).
  def mint(web_call_budget: 16, token_budget: 1_000_000, spend_budget_usd: 1.0)
    tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = tenancy[:user_id]
    @quest_id = tenancy[:quest_id]
    conn[:quests].where(id: @quest_id).update(
      web_call_budget: web_call_budget, token_budget: token_budget,
      spend_budget_usd: spend_budget_usd
    )
    @session = {id: tenancy[:session_id], user_id: tenancy[:user_id], quest_id: tenancy[:quest_id],
                phase_id: tenancy[:phase_id], model: "test-model", driver: "orchestrator"}
    tenancy
  end

  # The frozen line, runtime-parsed from the tool's fixture file.
  def frozen_refusal(tool, class_id)
    Kquest::Tools::Texts.frozen_refusal(tool, class_id)
  end

  # The frozen canonical ```text answer block (the answer-shape law).
  def frozen_answer(tool)
    Kquest::Tools::Texts.answer_block(tool)
  end

  def default_config
    @default_config ||= Kquest::Tools::DEFAULT_CONFIG.dup
  end

  def build_tool(name, config: nil, runner: nil)
    Kquest::Tools.build(name, conn: conn, session: @session, ledger: nil,
                        config: config || default_config, runner: runner)
  end

  # The refusal law (AC3): trigger the class with KNOWN values, byte-compare
  # the produced line against the runtime-parsed frozen line with the SAME
  # slots substituted, and prove the planted located values actually landed
  # (breaks the circular registry hole — a pattern that failed to hit would
  # leave the frozen example values in both sides).
  def assert_refusal(tool, class_id, slots:, planted: [])
    produced = assert_raises(Kquest::Engine::Error) do
      yield
    end
    assert_equal Kquest::Tools::Texts.error_class(tool, class_id), produced.error_class,
                 "the census-able rule-id token is the error_class (DR-01)"
    assert_equal Kquest::Tools::Texts.refusal(tool, class_id, **slots), produced.message,
                 "byte-matched against the runtime-parsed frozen fixtures/#{tool}.md line"
    planted.each { |value| assert_includes produced.message, value.to_s }
    produced
  end

  # Runs a tool call inside the reactor it needs (the wire clients are
  # fiber-native) and returns the result.
  def execute_tool(tool, **args)
    Sync { tool.execute(**args) }
  end

  # A staged source with a snapshot blob (the anchoring target) — the
  # content-addressed row + quest membership the FetchBody shape mints.
  def mint_source(snapshot:, role: "citable", title: "Fixture source", added_at: Time.now)
    require "digest"
    require "stringio"
    urn = "kb:src:" + Kquest::Pipeline::Base58.encode(SecureRandom.bytes(12))[0, 10]
    sha = Digest::SHA256.hexdigest(snapshot)
    Kquest::BlobUploader.store(StringIO.new(snapshot), kind: :snapshot, user: @user_id,
                               source_urn: urn)
    source_id = conn[:sources].insert(
      user_id: @user_id, url: "https://example.test/#{urn}", canonical_url: "https://example.test/#{urn}",
      urn: urn, title: title, role: role, fetched_at: Time.now,
      snapshot_sha256: sha, raw_sha256: sha, snapshot_char_count: snapshot.length
    )
    conn[:quest_sources].insert(quest_id: @quest_id, source_id: source_id, user_id: @user_id,
                                added_at: added_at)
    {id: source_id, urn: urn, text: snapshot}
  end

  # A staged CLAIM vector row (the near leg's data) in the LOCAL test table.
  def mint_claim_vector(claim_id, vector)
    job = PipelineFixtures.mint_embed_job(
      conn, user_id: @user_id, quest_id: @quest_id, phase_id: @session.fetch(:phase_id),
      kind: "embed", model_id: PipelineFixtures::MINILM_MODEL_ID, target_kind: "claim",
      idem_key: "embed:test:claim:#{SecureRandom.hex(4)}"
    )
    conn[:emb_minilm_ab_384].insert(
      model_id: PipelineFixtures::MINILM_MODEL_ID, model_status: "active",
      user_id: @user_id, target_kind: "claim", claim_id: claim_id,
      embedding: "[#{vector.join(',')}]", embedded_text: "fixture", job_id: job
    )
  end

  def mock_registry_config(mock_server)
    # The hermetic posture: the LOCAL test registry row points the pipeline
    # at the mock, and the DB's tool_config row names it (config data — the
    # seeds' delete+insert law re-heals at the next prepare; the cleanup
    # sweep empties the table, so UPSERT).
    PipelineFixtures.register_test_model(conn, mock_server)
    set_tool_config("tools.claim_embedding_model", text: PipelineFixtures::MINILM_MODEL_ID)
    default_config
  end

  # The tool_config upsert (the cleanup sweep empties the table; the tests
  # mint their own rows — the standing config-data law).
  # The subagent_profiles rows (config data — the cleanup sweep empties the
  # table; tests mint the day-one profiles verbatim).
  def mint_profiles
    conn[:subagent_profiles].where(name: "survey").delete
    conn[:subagent_profiles].insert(name: "survey", tools: JSON.generate(%w[status mass
      node_get neighbors search list paths source_read source_grep source_list retrieve]),
      provenance: "I05 §8 verbatim (test-minted)")
    conn[:subagent_profiles].where(name: "operator").delete
    conn[:subagent_profiles].insert(name: "operator",
      tools: JSON.generate(%w[node_add node_set node_get edge_add frontier_add frontier_close
        status search list paths mass neighbors source_read source_grep source_list
        web_search web_fetch retrieve report_draft report_bind harness quest_status
        subagent_spawn subagent_status]),
      provenance: "I05 §8 verbatim (test-minted)")
    nil
  end

  def set_tool_config(key, num: nil, text: nil)
    conn[:tool_config].where(key: key).delete
    conn[:tool_config].insert(key: key, num_value: num, text_value: text,
                              provenance: "test-minted config data")
    nil
  end
end

# The fixture-texts loader's own tests (I14 Part 2 / AC2): the census, the
# canonical calls, the substitution law's loud failure, spot byte-matches,
# and the §3.9 success notes byte-pinned against DESIGN.md §3.9 parsed at
# runtime (the landed I13 pinned-constants pattern).
class TextsTest < Minitest::Test
  include ToolRig

  DESIGN = File.expand_path("../../design/I05-tool-surface/DESIGN.md", __dir__)

  def test_loader_census_24_tools_50_refusal_sections
    assert_equal 24, Kquest::Tools::Texts.tool_names.size
    # 51: the tool count is UNTOUCHED (24 — no new tool); the refusal count
    # grew by ONE — report_draft's phase-not-synthesis (I20 Part 6, the I17
    # MINOR's frozen teaching section). The I18 PH0-11 law-beats-enumeration
    # class: the landed census flips with the law, the name is historical.
    assert_equal 51, Kquest::Tools::Texts.tool_names
                          .sum { |n| Kquest::Tools::Texts.refusal_classes(n).size }
  end

  def test_every_tool_carries_a_canonical_call
    Kquest::Tools::Texts.tool_names.each do |name|
      refute_empty Kquest::Tools::Texts.canonical_calls(name), "fixtures/#{name}.md"
    end
  end

  def test_unknown_refusal_class_raises_loudly
    assert_raises(KeyError) { Kquest::Tools::Texts.refusal("node_add", "no-such-class") }
    assert_raises(StandardError) { Kquest::Tools::Texts.refusal("no_such_tool", "unknown-node") }
  end

  def test_missing_slot_raises_loudly
    assert_raises(KeyError) { Kquest::Tools::Texts.refusal("edge_add", "unknown-node") }
  end

  def test_byte_match_spot_checks
    assert_equal frozen_refusal("edge_add", "unknown-node").gsub("<id>", "K9"),
                 Kquest::Tools::Texts.refusal("edge_add", "unknown-node", id: "K9")
    assert_equal frozen_refusal("node_add", "duplicate-label").gsub(/\bK12\b/, "K3"),
                 Kquest::Tools::Texts.refusal("node_add", "duplicate-label", existing: "K3")
  end

  def test_harness_fixture_carries_the_three_landed_texts
    assert_equal %w[tool-deadline unknown-tool write-guard], Kquest::Tools::Texts.refusal_classes("harness").sort
  end

  def test_success_notes_byte_pinned_against_design_39
    design = File.read(DESIGN)
    section = design.split("### 3.9 ").fetch(1)
    bare = section[/`\(satisfies nothing[^\n`]*`/].delete_prefix("`").delete_suffix("`")
    unreferenced = section[/`\(unreferenced[^\n`]*`/].delete_prefix("`").delete_suffix("`")
    coercion = section[/`\(coerced [^\n`]*`/].delete_prefix("`").delete_suffix("`")
    dedup = section[/`dedup candidates: \[K<m>[^\n`]*`/].delete_prefix("`").delete_suffix("`")
    budget = section[/`web_calls=<used>\/<cap>`/]
    cap_note = section[/`\(capped at <n> rows[^\n`]*`/].delete_prefix("`").delete_suffix("`")

    assert_equal bare, Kquest::Tools::Texts.bare_note
    assert_equal unreferenced, Kquest::Tools::Texts.unreferenced_note
    assert_equal coercion.sub("<what>", "terminal:string→object"),
                 Kquest::Tools::Texts.coercion_note("terminal:string→object")
    assert_equal dedup.sub("[K<m> (near_dup, cosine 0.82)]", "[K3 (near_dup, cosine 0.81)]"),
                 Kquest::Tools::Texts.dedup_candidates_note("K3 (near_dup, cosine 0.81)")
    assert_equal "web_calls=42/1400", Kquest::Tools::Texts.budget_echo_note(used: 42, cap: 1400)
    assert_includes budget, "web_calls=<used>/<cap>"
    assert_equal cap_note.sub("<n>", "50").sub("<last-id>", "K50"),
                 Kquest::Tools::Texts.cap_note(n: 50, last_id: "K50")
  end

  def test_error_class_is_the_census_token
    assert_equal "DUPLICATE-LABEL", Kquest::Tools::Texts.error_class("node_add", "duplicate-label")
    assert_equal "NON-SLICED-READ", Kquest::Tools::Texts.error_class("source_read", "non-sliced-read")
    assert_equal "MODEL-NAME-REFUSED", Kquest::Tools::Texts.error_class("retrieve", "model-name-refused")
  end
end
