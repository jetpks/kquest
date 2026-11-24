# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/pipeline_fixtures"
require_relative "../support/mock_completions_server"

# ProviderDesk + the SeedDecorator — the provider seam (I04 §3/§8) and the
# DR-07 mechanism-a delivery path (judge F1). FM-03 / FM-10 / FM-26 /
# E-SEED / E-PROTO land here. All keyless: the hermetic mock IS the wire.
class ProviderDeskTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @mock = MockCompletionsServer.new.start
    @config = Kquest::Engine::DEFAULT_CONFIG.transform_values { |v| {value: v, mode: "advisory"} }
  end

  def teardown
    @mock&.stop
    PipelineFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  def mint!
    @tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    @tenancy
  end

  def provider_row(overrides = {})
    name = "desk-#{SecureRandom.hex(4)}"
    conn[:llm_providers].insert(
      name: name, base_url: @mock.url, api_key_ref: nil, dialect: nil,
      model_id: "engine-test-model", context_window: 8192, max_tokens: 512,
      reasoning: false, **overrides
    )
    conn[:llm_providers].where(name: name).first
  end

  def session_for(tenancy, row)
    {id: tenancy[:session_id], user_id: tenancy[:user_id], quest_id: tenancy[:quest_id],
     phase_id: tenancy[:phase_id], model: row[:model_id]}
  end

  def desk_for(row, tenancy)
    Kquest::Engine::ProviderDesk.new(conn: conn, provider_row: row,
                                     session: session_for(tenancy, row))
  end

  # FM-03 — the decorator: fill-if-absent (no seed → a fresh random Integer
  # injected per request), an explicit seed wins (deterministic replay
  # tooling). E-SEED: every completion request carries a non-pinned seed.
  def test_FM03_decorator_fills_absent_seed_and_explicit_seed_wins # E-SEED
    tenancy = mint!
    row = provider_row(max_retries: 0)
    desk = desk_for(row, tenancy)
    chat = Fast::Completions::Chat.new(client: desk.client, model: desk.model)
    @mock.script([{type: :text, content: "one"}, {type: :text, content: "two"},
                  {type: :text, content: "three"}])

    Sync do
      chat.with_instructions("fill test")
      chat.step
      chat.add_message(Fast::Completions::Message.user("explicit"))
      chat.step
      # an explicit seed wins: the request carries it verbatim
      desk.client.stream(model: desk.model, messages: [], seed: 424_242)
    end

    bodies = @mock.captured_requests
    assert_equal 3, bodies.size
    seeds = bodies.map { |b| b["seed"] }
    assert seeds.all? { |s| s.is_a?(Integer) }, "every request carries a seed"
    refute_nil seeds[0]
    refute_nil seeds[1]
    refute_equal seeds[0], seeds[1], "two fill-injected requests never share a seed"
    assert_equal 424_242, bodies[2]["seed"], "an explicit seed wins (replay tooling)"
    assert_nil bodies[0]["temperature"], "the Chat path carries no temperature (judge F1)"
  ensure
    desk&.close
  end

  # FM-03 — the replay loop is STRUCTURALLY impossible: no two consecutive
  # requests share (body, seed) — every retry/fresh request injects a new
  # seed, so an identical body can never replay byte-identically.
  def test_FM03_no_two_consecutive_requests_share_body_and_seed
    tenancy = mint!
    row = provider_row(max_retries: 0)
    desk = desk_for(row, tenancy)
    @mock.script([{type: :text, content: "a"}, {type: :text, content: "b"}])
    chat = Fast::Completions::Chat.new(client: desk.client, model: desk.model)

    Sync do
      chat2 = chat
      2.times do
        chat2.with_instructions("same body every time")
        chat2.step
      end
    end
    logs = @mock.captured_request_logs
    pairs = logs.map { |entry| [entry[:body], entry[:body]["seed"]] }

    assert_equal 2, pairs.size
    refute_equal pairs[0][1], pairs[1][1], "identical bodies carried different seeds"
    keys = @mock.captured_requests.first.keys
    assert keys.include?("seed"), "the seed reaches the wire (DR-07 landed in the gem)"
  ensure
    desk&.close
  end

  # FM-10 / E-PROTO — an unknown dialect NAME raises ArgumentError AT BOOT
  # (ProviderDesk construction), never a silent plain-arm fallback.
  def test_FM10_unknown_dialect_name_raises_at_boot # E-PROTO
    tenancy = mint!
    row = provider_row(dialect: "no-such-dialect")

    error = assert_raises(ArgumentError) { desk_for(row, tenancy) }
    assert_match(/unknown dialect declaration/, error.message)
  end

  # FM-10 / E-PROTO — an unknown dialect KEY in a declaration raises
  # ArgumentError at declaration time (the gem's closed 14-key vocabulary —
  # keyword-override form; the block DSL raises NoMethodError for unknown
  # setters, which is equally boot-loud).
  def test_FM10_unknown_dialect_key_raises_at_declaration
    assert_raises(ArgumentError) do
      Fast::Completions.dialect(:engine_test_bad, bogus_key: true)
    end
  end

  # FM-26 — a FINAL 401 (gem-final class, never retried): the mapped error
  # class surfaces verbatim, NO retry, and the loop pauses the quest for
  # credential reconfiguration.
  def test_FM26_final_401_surfaces_verbatim_no_retry_quest_pauses
    tenancy = mint!
    row = provider_row(max_retries: 0)
    desk = desk_for(row, tenancy)
    @mock.script([{type: :status, status: 401, message: "stale credential"}])

    supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn)
    governor = Kquest::Engine::RetryGovernor.new(conn: conn, config: @config, supervisor: supervisor,
                                                 sleeper: ->(_) {})
    ledger = Kquest::Engine::TranscriptLedger.new(conn: conn, session: session_for(tenancy, row))
    budgeter = Kquest::Engine::ContextBudgeter.new(conn: conn, session: session_for(tenancy, row),
                                                   desk: desk, config: @config)
    harness = Kquest::Engine::ToolHarness.new(conn: conn, session: session_for(tenancy, row),
                                              ledger: ledger, config: @config)
    contract = Object.new
    contract.define_singleton_method(:assemble_context) { |_t| {instructions: "x", messages: []} }
    contract.define_singleton_method(:terminal?) { |**_| false }
    contract.define_singleton_method(:max_turns) { 5 }
    driver = Kquest::Engine::LoopDriver.new(conn: conn, desk: desk, harness: harness, ledger: ledger,
                                            budgeter: budgeter, watch: nil, governor: governor,
                                            supervisor: supervisor, contract: contract, config: @config)

    error = assert_raises(Kquest::Engine::Error) do
      Sync { driver.run }
    end
    assert_match(/terminal failure \(no retry\): Fast::Completions::AuthenticationError/, error.message)
    assert_match(/401: stale credential/, error.message) # the mapped class + status VERBATIM
    assert_equal 1, @mock.captured_requests.size, "NO retry — the 401 is gem-final"
    assert_equal "paused", conn[:quests].where(id: tenancy[:quest_id]).get(:state)
    event = conn[:quest_lifecycle_events].where(quest_id: tenancy[:quest_id]).first
    refute_nil event, "the quest pauses LEDGERED (active → paused) for credential reconfiguration"
    assert_equal "active", event[:from_state]
    assert_equal "paused", event[:to_state]
  end

  # The api_key_ref path goes through the CONSUMED Kquest::Pipeline::KeyRef
  # law (G-REG posture: NULL → no Authorization header; env:NAME → resolved).
  def test_api_key_ref_resolves_through_the_landed_keyref_law
    tenancy = mint!
    row = provider_row
    desk = desk_for(row, tenancy)
    @mock.script([{type: :text, content: "no key needed"}])
    Sync { desk.client.stream(model: desk.model, messages: []) }

    log = @mock.captured_request_logs.first
    refute log[:headers]["authorization"], "a NULL api_key_ref sends NO Authorization header " \
                                          "(a local engine needs none)"

    ENV["ENGINE_TEST_KEY"] = "test-only-not-a-secret" # KeyRef resolves at desk construction
    row2 = provider_row(api_key_ref: "env:ENGINE_TEST_KEY")
    desk2 = desk_for(row2, tenancy)
    @mock.script([{type: :text, content: "keyed"}])
    Sync { desk2.client.stream(model: desk2.model, messages: []) }
    log2 = @mock.captured_request_logs.last
    assert_equal "Bearer test-only-not-a-secret", log2[:headers]["authorization"]
  ensure
    ENV.delete("ENGINE_TEST_KEY")
    desk&.close
    desk2&.close
  end

  # An UNRESOLVABLE env: reference is a LOUD refusal (KeyRef's own law —
  # consumed, not duplicated).
  def test_unresolvable_env_ref_is_a_loud_refusal
    tenancy = mint!
    row = provider_row(api_key_ref: "env:ENGINE_TEST_KEY_UNSET")
    ENV.delete("ENGINE_TEST_KEY_UNSET")

    error = assert_raises(Kquest::Pipeline::Error) { desk_for(row, tenancy) }
    assert_match(/ENGINE_TEST_KEY_UNSET is not set/, error.message)
  end

  # E-NOECHO support fact: the desk's identity lives on the row/session —
  # the desk NEVER hands identity to the prompt path (the driver enforces;
  # see loop_driver_test).
  def test_desk_exposes_row_and_model_identity_only_as_config
    tenancy = mint!
    row = provider_row
    desk = desk_for(row, tenancy)
    assert_equal "engine-test-model", desk.model.id
    assert_equal row[:name], desk.model.provider
    assert desk.reports_usage?
  ensure
    desk&.close
  end
end
