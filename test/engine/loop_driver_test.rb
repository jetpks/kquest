# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/pipeline_fixtures"
require_relative "../support/mock_completions_server"

# The LoopDriver — the turn cycle (I04 §2.2). FM-01 / FM-17 / E-NOECHO land
# here. All keyless: the hermetic mock IS the wire.
class LoopDriverTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @mock = MockCompletionsServer.new.start
    @sleeps = []
    @config = Kquest::Engine::DEFAULT_CONFIG.transform_values { |v| {value: v, mode: "advisory"} }
  end

  def teardown
    @mock&.stop
    # two builds in the E-NOECHO test mint TWO tenancies — clean every one
    Array(@minted_users).each { |uid| PipelineFixtures.cleanup(conn, user_id: uid) }
  end

  def mint_user!(tenancy)
    (@minted_users ||= []) << tenancy[:user_id]
    tenancy
  end

  def build_engine(contract:, tools: [], config_overrides: {}, max_retries: 0, tenancy: nil)
    tenancy ||= mint_user!(PipelineFixtures.mint_tenancy(conn))
    @user_id = tenancy[:user_id]
    conn[:llm_providers].where(name: "driver-test-provider").delete
    conn[:llm_providers].insert(name: "driver-test-provider", base_url: @mock.url,
                                api_key_ref: nil, model_id: "engine-test-model",
                                context_window: 8192, max_tokens: 512, reasoning: false,
                                max_retries: max_retries)
    row = conn[:llm_providers].where(name: "driver-test-provider").first
    session = {id: tenancy[:session_id], user_id: tenancy[:user_id], quest_id: tenancy[:quest_id],
               phase_id: tenancy[:phase_id], model: row[:model_id]}
    @session_id = session[:id]
    @quest_id = session[:quest_id]
    @phase_id = session[:phase_id]
    desk = Kquest::Engine::ProviderDesk.new(conn: conn, provider_row: row, session: session)
    ledger = Kquest::Engine::TranscriptLedger.new(conn: conn, session: session)
    budgeter = Kquest::Engine::ContextBudgeter.new(conn: conn, session: session, desk: desk,
                                                   config: @config.merge(config_overrides))
    supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn)
    supervisor.live_sessions.add(session[:id])
    governor = Kquest::Engine::RetryGovernor.new(conn: conn, config: @config.merge(config_overrides),
                                                 supervisor: supervisor,
                                                 sleeper: ->(s) { @sleeps << s })
    harness = Kquest::Engine::ToolHarness.new(conn: conn, session: session, ledger: ledger,
                                              config: @config.merge(config_overrides),
                                              write_guard: supervisor.write_guard_for(session))
    driver = Kquest::Engine::LoopDriver.new(conn: conn, desk: desk, harness: harness, ledger: ledger,
                                            budgeter: budgeter, watch: nil, governor: governor,
                                            supervisor: supervisor, contract: contract,
                                            config: @config.merge(config_overrides), tools: tools)
    [driver, {tenancy: tenancy, session: session, row: row, desk: desk, ledger: ledger,
              budgeter: budgeter, supervisor: supervisor, governor: governor, harness: harness}]
  end

  def text_contract(max_turns: 10)
    contract = Object.new
    contract.define_singleton_method(:assemble_context) do |turn|
      {instructions: "the scripted phase instructions", messages: []}
    end
    last = ->(chat) { chat.messages.last&.to_h }
    contract.define_singleton_method(:terminal?) do |turn:, chat:|
      message = last.call(chat)
      chat.complete? && turn >= 1 && message && message[:content].is_a?(Array) &&
        message[:content].any? { |b| b.is_a?(Hash) && b[:type] == :text && !b[:text].strip.empty? }
    end
    contract.define_singleton_method(:max_turns) { max_turns }
    contract
  end

  # FM-01 — an `:empty` reply retries the turn with a FRESH seed in-session,
  # counts the phase attempt, escalates at cap — never silent.
  def test_FM01_empty_completion_retries_fresh_seed_counts_attempt
    @mock.script([{type: :empty}, {type: :text, content: "recovered"}])
    driver, rig = build_engine(contract: text_contract)

    Sync { driver.run }

    seeds = @mock.captured_requests.map { |b| b["seed"] }
    assert_equal 2, seeds.size
    refute_equal seeds[0], seeds[1], "the retry carries a FRESH seed (E-SEED)"
    assert_equal 2, conn[:phases].where(id: @phase_id).get(:attempt_no) - 1 + 1 # counted
    assert_equal 2, conn[:phases].where(id: @phase_id).get(:attempt_no), "the phase attempt is counted"
  end

  # FM-01 at cap: bank the session + end the phase attempt LOUDLY.
  def test_FM01_empty_completion_at_cap_banks_and_escalates_loudly
    @mock.script([{type: :empty}, {type: :empty}, {type: :empty}])
    driver, rig = build_engine(contract: text_contract)

    error = assert_raises(Kquest::Engine::Error) { Sync { driver.run } }
    assert_match(/FM-01: empty completion exhausted the phase attempt cap \(3\)/, error.message)
    assert_equal 3, conn[:phases].where(id: @phase_id).get(:attempt_no)
    refute_nil conn[:sessions].where(id: @session_id).get(:ended_at), "the session is banked"
  end

  # FM-17 — a tiny `quests.token_budget`: the turn-boundary rollup (over
  # usage_events — L10, budgets read the ledger) stops new turns and pauses
  # the quest; the never-reportless ROUTE is recorded (the finisher itself
  # is ENTRY 4's).
  def test_FM17_tiny_token_budget_stops_new_turns_and_pauses_quest
    tenancy = mint_user!(PipelineFixtures.mint_tenancy(conn))
    @user_id = tenancy[:user_id]
    conn[:quests].where(id: tenancy[:quest_id]).update(token_budget: 1)
    conn[:usage_events].insert(user_id: tenancy[:user_id], quest_id: tenancy[:quest_id],
                               phase_id: tenancy[:phase_id], session_id: tenancy[:session_id],
                               kind: "llm", model: "engine-test-model", input_tokens: 100,
                               output_tokens: 5)
    @mock.script([{type: :text, content: "never reached"}])
    driver, rig = build_engine(contract: text_contract, tenancy: tenancy)

    result = Sync { driver.run }

    assert_equal :budget_paused, result
    assert_equal "paused", conn[:quests].where(id: tenancy[:quest_id]).get(:state)
    event = conn[:quest_lifecycle_events].where(quest_id: tenancy[:quest_id]).first
    assert_equal ["active", "paused"], [event[:from_state], event[:to_state]]
    assert_match(/never-reportless/, driver.result_notes.first[:route])
    assert_equal 0, @mock.captured_requests.size, "no new turn starts at the boundary"
  end

  # E-NOECHO — the assembled prompt carries NO model/config identity strings;
  # identity lives in sessions.model/usage_events.model only.
  def test_E_NOECHO_assembled_context_carries_no_identity_strings
    @mock.script([{type: :text, content: "fine"}])
    driver, rig = build_engine(contract: text_contract)
    Sync { driver.run } # the clean contract passes

    leaking = text_contract
    model_id = rig[:row][:model_id]
    leaking.define_singleton_method(:assemble_context) do |_t|
      {instructions: "oops: #{model_id}", messages: []}
    end
    driver2, _ = build_engine(contract: leaking)
    @mock.rearm!

    error = assert_raises(Kquest::Engine::Error) { Sync { driver2.run } }
    assert_match(/prompt-echo prohibition \(E-NOECHO\)/, error.message)
  end
end
