# frozen_string_literal: true

require_relative "../test_helper"
require "fast/completions"
require_relative "../support/pipeline_fixtures"
require_relative "../support/mock_completions_server"

# The ToolHarness — the dispatch contract (I04 §2.4). FM-04 / FM-11 / FM-12 /
# the FM-16 write-guard leg / E-AUDIT / E-WEDGE land here. The three frozen
# `harness.md` refusal texts are BYTE-MATCHED by runtime-parsing the frozen
# fixture file (design/ is read-only law — the parse path below is the only
# place the texts come from; no copies in test code).
class ToolHarnessTest < Minitest::Test
  # ── the frozen fixture, parsed AT RUNTIME (never copied) ───────────────
  HARNESS_FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/harness.md", __dir__)

  def self.frozen_refusal(section)
    text = File.read(HARNESS_FIXTURE)
    body = text.split("### refusal: #{section}\n").fetch(1)
    body[/```\n(.*?)\n```/m].delete_prefix("```\n").delete_suffix("\n```").strip
  end

  def frozen_refusal(section) = self.class.frozen_refusal(section)

  def refusal_from_transcript(ledger, prefix)
    ledger.sink.blobs.values.join.split("\n")
         .map { |line| JSON.parse(line) rescue nil }.compact
         .select { |r| r.is_a?(Hash) && r["type"] == "tool_result" }
         .map { |r| r["content"] }
         .find { |content| content.to_s.start_with?(prefix) }
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @mock = MockCompletionsServer.new.start
    @config = Kquest::Engine::DEFAULT_CONFIG.transform_values { |v| {value: v, mode: "advisory"} }
  end

  def teardown
    @mock&.stop
    PipelineFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  # ── the rig ──────────────────────────────────────────────────────────

  def build_engine(contract:, tools: [], config_overrides: {}, write_guard: :default, tenancy: nil)
    tenancy ||= PipelineFixtures.mint_tenancy(conn)
    @user_id = tenancy[:user_id]
    conn[:llm_providers].where(name: "harness-test-provider").delete
    conn[:llm_providers].insert(name: "harness-test-provider", base_url: @mock.url,
                                api_key_ref: nil, model_id: "engine-test-model",
                                context_window: 8192, max_tokens: 512, reasoning: false,
                                max_retries: 0)
    row = conn[:llm_providers].where(name: "harness-test-provider").first
    session = {id: tenancy[:session_id], user_id: tenancy[:user_id], quest_id: tenancy[:quest_id],
               phase_id: tenancy[:phase_id], model: row[:model_id]}
    @session_id = session[:id]
    @quest_id = session[:quest_id]
    cfg = @config.merge(config_overrides)
    desk = Kquest::Engine::ProviderDesk.new(conn: conn, provider_row: row, session: session)
    ledger = Kquest::Engine::TranscriptLedger.new(conn: conn, session: session)
    budgeter = Kquest::Engine::ContextBudgeter.new(conn: conn, session: session, desk: desk, config: cfg)
    supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn)
    supervisor.live_sessions.add(session[:id])
    guard =
      if write_guard == :default
        supervisor.write_guard_for(session)
      else
        write_guard
      end
    governor = Kquest::Engine::RetryGovernor.new(conn: conn, config: cfg, supervisor: supervisor,
                                                 sleeper: ->(_) {})
    harness = Kquest::Engine::ToolHarness.new(conn: conn, session: session, ledger: ledger,
                                              config: cfg, write_guard: guard, budgeter: budgeter)
    driver = Kquest::Engine::LoopDriver.new(conn: conn, desk: desk, harness: harness, ledger: ledger,
                                            budgeter: budgeter, watch: nil, governor: governor,
                                            supervisor: supervisor, contract: contract,
                                            config: cfg, tools: tools)
    [driver, {session: session, desk: desk, ledger: ledger, harness: harness, supervisor: supervisor,
              budgeter: budgeter}]
  end

  def terminal_on_text_contract
    contract = Object.new
    contract.define_singleton_method(:assemble_context) { |_t| {instructions: "i", messages: []} }
    last = ->(chat) { chat.messages.last&.to_h }
    contract.define_singleton_method(:terminal?) do |turn:, chat:|
      message = last.call(chat)
      chat.complete? && turn >= 1 && message && message[:content].is_a?(Array) &&
        message[:content].any? { |b| b.is_a?(Hash) && b[:type] == :text && !b[:text].strip.empty? }
    end
    contract.define_singleton_method(:max_turns) { 10 }
    contract
  end

  # ── test tools ───────────────────────────────────────────────────────

  class SleepingTool < Fast::Completions::Tool
    description "sleeps"
    tool_name "sleep_tool"
    parameters { {"type" => "object", "properties" => {}} }

    def ran_description(**_args) = "sleep_tool pattern=wide src=everything"

    def execute(**_args)
      sleep 30
      "never returns"
    end
  end

  class ClaimTool < Fast::Completions::Tool
    description "inserts a claim (a MUTATION)"
    tool_name "claim_writer"
    parameters { {"type" => "object", "properties" => {"text" => {"type" => "string"}}} }

    def mutates? = true

    # Instances are pre-bound to their tenancy (with_tools takes instances;
    # the tool's writes JOIN the harness's same-transaction audit through the
    # shared conn).
    def initialize(conn:, user_id:, quest_id:)
      @conn = conn
      @user_id = user_id
      @quest_id = quest_id
    end

    def execute(text:, **_rest)
      seq = (@conn[:claims].where(quest_id: @quest_id).max(:quest_seq) || 0) + 1
      # the DR-06 quest-salted URN, minted exactly like the fixture law
      urn = "kb:claim:" + Kquest::Pipeline::Base58
        .encode(Digest::SHA256.digest(@quest_id + text))[0, 10]
      @conn[:claims].insert(user_id: @user_id, quest_id: @quest_id, quest_seq: seq,
                            text: text, urn: urn)
      {written: text}
    end
  end

  class EchoTool < Fast::Completions::Tool
    description "echoes"
    tool_name "echo_tool"
    parameters { {"type" => "object", "properties" => {"say" => {"type" => "string"}}} }

    def execute(say: "", **_rest) = {echo: say}
  end

  # ── FM-04: the tool deadline (E-WEDGE) ─────────────────────────────────

  # A sleeping tool past a tiny tool_timeout_s → the frozen `tool-deadline`
  # refusal (byte-matched from harness.md), the session survives and routes
  # around it.
  def test_FM04_tool_past_deadline_gets_the_frozen_refusal_and_the_session_survives # E-WEDGE
    @mock.script([
      {type: :tool_use, tool_calls: [{id: "call-1", name: "sleep_tool", arguments: {}}]},
      {type: :text, content: "routed around the wedge"}
    ])
    # tiny deadline: the config value is test data (the frozen default is 120s)
    cfg = @config.merge("engine.tool_timeout_s" => {value: 0.3, mode: "advisory"})
    driver, rig = build_engine(contract: terminal_on_text_contract, tools: [SleepingTool],
                               config_overrides: cfg)

    Sync { driver.run }

    refusal = refusal_from_transcript(rig[:ledger], "REFUSAL: TOOL-DEADLINE")
    refute_nil refusal, "the teaching refusal reached the transcript"
    template = frozen_refusal("tool-deadline")
    elapsed = refusal[/elapsed (\d+)s/, 1]
    ran = refusal[/ran: ([^)]*)\)/, 1]
    expected = template.gsub("<tool>", "sleep_tool")
                       .sub(/elapsed \d+s/, "elapsed #{elapsed}s")
                       .sub(/ran: [^)]+\)/, "ran: #{ran})")
    assert_equal expected, refusal, "byte-matched against the frozen harness.md template"
    assert_equal 1, conn[:tool_calls].where(session_id: @session_id).where(ok: false, error_class: "ToolDeadline").count
    assert @mock.captured_requests.size >= 2, "the session survived and routed around"
  end

  # ── FM-11: the ToolArgumentsFailure marker ─────────────────────────────

  # A tool_call finalizing to the ToolArgumentsFailure marker → that call's
  # is_error result carrying the marker VERBATIM; never executed, never a
  # silent {}.
  def test_FM11_tool_arguments_failure_marker_becomes_verbatim_is_error_result
    @mock.script([
      {type: :tool_use, tool_calls: [{id: "call-1", name: "echo_tool",
                                      arguments: "{broken json:: no parse"}]},
      {type: :text, content: "re-called after the marker"}
    ])
    driver, rig = build_engine(contract: terminal_on_text_contract, tools: [EchoTool])

    Sync { driver.run }

    audit = conn[:tool_calls].where(session_id: @session_id).first
    refute_nil audit
    assert_equal false, audit[:ok]
    assert_equal "ToolArgumentsFailure", audit[:error_class]
    assert_equal Fast::Completions::ToolArgumentsFailure::MESSAGE, audit[:result]["content"]
    assert_equal true, audit[:result]["is_error"]
  end

  # ── FM-12: the unknown-tool teaching refusal (byte-matched) + the
  #    wedge-guard alert ──────────────────────────────────────────────────

  def test_FM12_unknown_tool_teaching_refusal_byte_matched_then_wedge_alert
    @mock.script([
      {type: :tool_use, tool_calls: [{id: "c1", name: "nonexistent_tool", arguments: {}}]},
      {type: :tool_use, tool_calls: [{id: "c2", name: "nonexistent_tool", arguments: {}}]},
      {type: :tool_use, tool_calls: [{id: "c3", name: "nonexistent_tool", arguments: {}}]},
      {type: :text, content: "done"}
    ])
    driver, rig = build_engine(contract: terminal_on_text_contract, tools: [EchoTool, SleepingTool])

    Sync { driver.run }

    template = frozen_refusal("unknown-tool")
    expected = template.gsub("<name>", "nonexistent_tool").gsub("<legal-tools>", "echo_tool, sleep_tool")
    refusal = refusal_from_transcript(rig[:ledger], "REFUSAL: no such tool")
    refute_nil refusal
    assert_equal expected, refusal, "byte-matched against the frozen harness.md template"
    alert = rig[:harness].alerts.first
    refute_nil alert, "3 consecutive unknown-tool calls escalate the wedge-guard alert"
    assert_equal "wedge_guard", alert[:type]
    assert_match(/stuck model, not a bad call/, alert[:message])
  end

  # ── FM-16: the write-guard recheck (defense-in-depth) ──────────────────

  def test_FM16_write_guard_refuses_a_mutation_batch
    @mock.script([
      {type: :tool_use, tool_calls: [{id: "c1", name: "claim_writer",
                                      arguments: {text: "should never land"}}]},
      {type: :text, content: "after the refusal"}
    ])
    holder = {id: SecureRandom.uuid, driver: "operator"}
    quest_id = SecureRandom.uuid
    guard = lambda do
      raise Kquest::Engine::Error.new(
        Kquest::Engine::ToolHarness::WRITE_GUARD_TEXT
          .gsub("<quest-id>", quest_id).gsub("<session-id>", holder[:id])
          .gsub("<driver>", holder[:driver]), error_class: "WriteGuard")
    end
    tenancy = PipelineFixtures.mint_tenancy(conn)
    driver, rig = build_engine(contract: terminal_on_text_contract,
                               tools: [ClaimTool.new(conn: conn, user_id: tenancy[:user_id],
                                                     quest_id: tenancy[:quest_id])],
                               write_guard: guard, tenancy: tenancy)

    Sync { driver.run }

    template = frozen_refusal("write-guard")
    expected = template.gsub("<quest-id>", quest_id).gsub("<session-id>", holder[:id])
                       .gsub("<driver>", "operator")
    refusal = refusal_from_transcript(rig[:ledger], "REFUSAL: WRITE-GUARD")
    refute_nil refusal
    assert_equal expected, refusal, "byte-matched against the frozen harness.md template"
    assert_equal 0, conn[:claims].where(quest_id: @quest_id).count, "nothing mutated behind a live writer"
    audit = conn[:tool_calls].where(session_id: @session_id).first
    assert_equal false, audit[:ok] # refusals are audited too (T-AUDIT)
  end

  # ── E-AUDIT: the audit row and the mutation roll back TOGETHER ─────────

  def test_E_AUDIT_audit_failure_rolls_back_the_mutation
    @mock.script([
      {type: :tool_use, tool_calls: [{id: "c1", name: "claim_writer",
                                      arguments: {text: "the claim text"}}]},
      {type: :text, content: "done"}
    ])
    tenancy = PipelineFixtures.mint_tenancy(conn)
    driver, rig = build_engine(contract: terminal_on_text_contract,
                               tools: [ClaimTool.new(conn: conn, user_id: tenancy[:user_id],
                                                     quest_id: tenancy[:quest_id])],
                               tenancy: tenancy)

    Sync { driver.run }

    # the happy path: the claims row AND its tool_calls audit row exist
    assert_equal 1, conn[:claims].where(quest_id: @quest_id).count
    audit = conn[:tool_calls].where(session_id: @session_id).first
    assert_equal true, audit[:ok]
    assert_equal "claim_writer", audit[:tool]
    assert_equal 1, audit[:seq], "the per-session seq starts at 1 (uq_tool_calls_session_seq)"

    # force an audit failure on a SECOND write: its claims row is ABSENT
    # (the audit row and the mutation roll back TOGETHER — E-AUDIT); the
    # first run's committed row survives.
    conn[:tool_calls].delete
    @mock.rearm!
    driver2, rig2 = build_engine(contract: terminal_on_text_contract,
                                 tools: [ClaimTool.new(conn: conn, user_id: tenancy[:user_id],
                                                       quest_id: tenancy[:quest_id])],
                                 tenancy: tenancy)
    rig2[:harness].stub(:audit_result, lambda { |*| raise Sequel::Error, "forced audit failure" }) do
      Sync { driver2.run }
    end
    assert_equal 1, conn[:claims].where(quest_id: tenancy[:quest_id]).count
    assert_equal 1, conn[:claims].where(quest_id: tenancy[:quest_id]).max(:quest_seq),
                 "run 2's claim rolled back with its audit row (E-AUDIT)"
  end

  # ── F4 (I20 Part 2): the audit savepoint ────────────────────────────

  # A rig tool whose execute performs a REAL server-side-failing write (the
  # uq_claims_quest_seq-violating INSERT is its last act): the savepoint
  # rolls the tool's own writes back, the audit row lands in the healthy
  # outer transaction (ok:false, error_class set — L8), and the model sees
  # the in-band {error:} outcome. RED before the fix: the aborted-transaction
  # error escaped invoke — no audit row, the whole batch rolled back.
  class SqlBreakingTool < Fast::Completions::Tool
    description "writes then breaks (a server-side SQL failure)"
    tool_name "sql_breaker"
    parameters { {"type" => "object", "properties" => {}} }

    def mutates? = true

    def initialize(conn:, user_id:, quest_id:)
      @conn = conn
      @user_id = user_id
      @quest_id = quest_id
    end

    def execute(**_args)
      seq = (@conn[:claims].where(quest_id: @quest_id).max(:quest_seq) || 0) + 1
      urn = "kb:claim:" + Kquest::Pipeline::Base58
        .encode(Digest::SHA256.digest(@quest_id + "the rolled-back claim"))[0, 10]
      @conn[:claims].insert(user_id: @user_id, quest_id: @quest_id, quest_seq: seq,
                            text: "the write that must roll back", urn: urn)
      # the constraint-violating INSERT (uq_claims_quest_seq) — then nothing else
      @conn[:claims].insert(user_id: @user_id, quest_id: @quest_id, quest_seq: seq,
                            text: "the colliding write",
                            urn: "kb:claim:" + Kquest::Pipeline::Base58.encode(
                              Digest::SHA256.digest(@quest_id + "the colliding write"))[0, 10])
      {written: "never"}
    end
  end

  def test_failed_tool_sql_leaves_its_audit_row
    tenancy = PipelineFixtures.mint_tenancy(conn)
    _, rig = build_engine(contract: terminal_on_text_contract,
                          tools: [SqlBreakingTool.new(conn: conn, user_id: tenancy[:user_id],
                                                      quest_id: tenancy[:quest_id])],
                          tenancy: tenancy)
    tool = SqlBreakingTool.new(conn: conn, user_id: tenancy[:user_id],
                               quest_id: tenancy[:quest_id])

    outcome = Sync { rig[:harness].invoke(tool, audit_name: "sql_breaker") }

    # (c) the model-visible outcome is the in-band {error:} — unchanged
    assert outcome.is_a?(Hash) && outcome.key?(:error), "failure isolation to THIS call"
    # (a) the audit row SURVIVED in the healthy outer transaction (L8)
    audit = conn[:tool_calls].where(session_id: rig[:session][:id], tool: "sql_breaker").first
    refute_nil audit, "the audit row lands even though the tool's SQL failed (F4/L8)"
    assert_equal false, audit[:ok]
    assert audit[:error_class], "error_class carries the SQL error (Sequel::UniqueConstraintViolation)"
    # (b) the failed tool's own writes are rolled back
    assert_equal 0, conn[:claims].where(quest_id: tenancy[:quest_id]).count,
                 "the savepoint rolled the tool's own writes back (L5 atomicity)"
  end
end
