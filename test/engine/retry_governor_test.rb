# frozen_string_literal: true

require_relative "../test_helper"
require "fast/completions"
require_relative "../support/pipeline_fixtures"
require_relative "../support/mock_completions_server"

# The RetryGovernor — the failure-table executor (I04 §2.5). FM-05 / FM-06 /
# FM-07 / FM-08 / FM-13 / FM-23 land here. The governor's backoff is injected
# (`sleeper:` records, never sleeps); the wire failures come from the hermetic
# mock. All keyless.
class RetryGovernorTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @mock = MockCompletionsServer.new.start
    @sleeps = []
    @config = Kquest::Engine::DEFAULT_CONFIG.transform_values { |v| {value: v, mode: "advisory"} }
  end

  def teardown
    @mock&.stop
    PipelineFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  def build_engine(contract:, config_overrides: {}, max_retries: 0, sleeper: nil, timeout_s: nil)
    tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = tenancy[:user_id]
    conn[:llm_providers].where(name: "governor-test-provider").delete
    conn[:llm_providers].insert(name: "governor-test-provider", base_url: @mock.url,
                                api_key_ref: nil, model_id: "engine-test-model",
                                context_window: 8192, max_tokens: 512, reasoning: false,
                                max_retries: max_retries, timeout_s: timeout_s)
    row = conn[:llm_providers].where(name: "governor-test-provider").first
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
    governor = Kquest::Engine::RetryGovernor.new(conn: conn, config: cfg, supervisor: supervisor,
                                                 sleeper: sleeper || ->(s) { @sleeps << s })
    harness = Kquest::Engine::ToolHarness.new(conn: conn, session: session, ledger: ledger, config: cfg)
    driver = Kquest::Engine::LoopDriver.new(conn: conn, desk: desk, harness: harness, ledger: ledger,
                                            budgeter: budgeter, watch: nil, governor: governor,
                                            supervisor: supervisor, contract: contract,
                                            config: cfg, tools: [])
    [driver, {session: session, desk: desk, ledger: ledger, governor: governor, supervisor: supervisor}]
  end

  def never_terminal_contract(max_turns: 12)
    contract = Object.new
    contract.define_singleton_method(:assemble_context) { |_t| {instructions: "i", messages: []} }
    contract.define_singleton_method(:terminal?) { |**_| false }
    contract.define_singleton_method(:max_turns) { max_turns }
    contract
  end

  # FM-05 — `:slow_ttfb` past the TTFB watchdog → TimeoutError → bounded
  # jittered retry (a FRESH seed each), bank + end attempt at cap.
  def test_FM05_slow_ttfb_timeout_bounded_jittered_retry_with_fresh_seeds
    # tiny provider timeout (0.5s) vs the mock's 2s first-byte delay; the gem's
    # L0 immediate retry disabled (max_retries 0) so each turn = one attempt
    @mock.script([{type: :slow_ttfb, delay: 2}, {type: :text, content: "recovered"}])
    driver, rig = build_engine(contract: never_terminal_contract(max_turns: 2), timeout_s: 0.5)

    Sync { driver.run }

    seeds = @mock.captured_requests.map { |b| b["seed"] }
    assert_operator seeds.size, :>=, 2
    refute_equal seeds[0], seeds[1], "each retry carries a fresh seed (E-SEED)"
    assert @sleeps.size >= 1, "jittered backoff ABOVE the gem's L0 fired"
    assert @sleeps.all? { |s| s.is_a?(Numeric) && s >= 0 }
  end

  # FM-06 — connection refused at creation → bounded retry; a ZERO-TOKEN
  # usage row per failed call; loud phase-attempt failure at cap.
  def test_FM06_connection_refused_bounded_retry_and_zero_token_rows
    @mock.stop # nothing listens: ECONNREFUSED at every creation
    driver, rig = build_engine(contract: never_terminal_contract)

    error = assert_raises(Kquest::Engine::Error) { Sync { driver.run } }
    assert_match(/connection retry cap exhausted/, error.message)
    # a zero-token usage row per failed call — the call is still an event
    rows = conn[:usage_events].where(session_id: @session_id, kind: "llm").all
    assert_operator rows.size, :>=, 1, "failed calls recorded their rows"
    rows.each do |row|
      assert_equal 0, row[:input_tokens]
      assert_equal 0, row[:output_tokens]
    end
  end

  # FM-07 — provider 429 with Retry-After: the LONGER class cap; at the bound
  # the quest PAUSES (lifecycle event ledgered), never loops silently.
  def test_FM07_rate_limit_at_bound_pauses_the_quest
    @mock.script(Array.new(6) { {type: :status, status: 429, message: "slow down",
                                 headers: {"retry-after" => "1"}} })
    driver, rig = build_engine(contract: never_terminal_contract)

    error = assert_raises(Kquest::Engine::Error) { Sync { driver.run } }
    assert_match(/rate_limit retry cap exhausted/, error.message)
    assert_equal 6, conn[:usage_events].where(session_id: @session_id).count,
                 "one zero-token spend row per failed call: the initial attempt + the cap's " \
                 "5 retries, every completion its own row"
    assert_equal "paused", conn[:quests].where(id: @quest_id).get(:state),
                 "a rate-limited provider is an operator-visible condition — the quest pauses"
    event = conn[:quest_lifecycle_events].where(quest_id: @quest_id).first
    assert_equal ["active", "paused"], [event[:from_state], event[:to_state]]
    assert_match(/FM-07/, event[:note])
    # the LONGER class cap: rate limit 5 > transport 3
    assert_equal 5, rig[:governor].cap_for(:rate_limit)
    assert_equal 3, rig[:governor].cap_for(:timeout)
  end

  # FM-08 — provider 5xx → bounded jittered retry; at the cap the phase
  # attempt fails loudly (banked), the quest does NOT pause.
  def test_FM08_server_error_at_cap_banks_loudly_without_pausing
    @mock.script(Array.new(4) { {type: :status, status: 503, message: "backend unavailable"} })
    driver, rig = build_engine(contract: never_terminal_contract)

    error = assert_raises(Kquest::Engine::Error) { Sync { driver.run } }
    assert_match(/server_error retry cap exhausted/, error.message)
    assert_equal 4, conn[:usage_events].where(session_id: @session_id).count,
                 "the initial attempt + the cap's 3 retries, each its own zero-token row"
    refute_nil conn[:sessions].where(id: @session_id).get(:ended_at), "the session is banked"
    assert_equal "active", conn[:quests].where(id: @quest_id).get(:state),
                 "a 5xx storm is a phase failure, not an operator-visible pause"
  end

  # FM-13 — `:missing_finish`: the salvaged partial + its usage persist as
  # audit, the turn retries with a fresh seed, cap 2 (then bank).
  def test_FM13_missing_finish_salvages_then_retries_fresh_seed_then_banks
    @mock.script([{type: :missing_finish}, {type: :text, content: "recovered after the salvage"}])
    driver, rig = build_engine(contract: never_terminal_contract(max_turns: 2))

    Sync { driver.run }

    # the salvage audit line persisted (never auto-appended to live history)
    blob = rig[:ledger].sink.blobs.values.join
    salvage = blob.split("\n").map { |l| JSON.parse(l) rescue nil }.compact
                   .find { |r| r["type"] == "salvage" }
    refute_nil salvage, "the salvaged partial persisted as audit"
    assert_operator salvage.dig("message", "usage", "total_tokens"), :>=, 18,
                   "the salvage carries the streamed usage (FM-13)"
    seeds = @mock.captured_requests.map { |b| b["seed"] }
    refute_equal seeds[0], seeds[1], "the turn retried with a fresh seed"
    assert_equal 2, conn[:usage_events].where(session_id: @session_id).count,
                 "one row per completion: the salvage AND the success"
  end

  def test_FM13_stream_retry_cap_banks_at_two
    @mock.script(Array.new(3) { {type: :missing_finish} })
    driver, rig = build_engine(contract: never_terminal_contract)

    error = assert_raises(Kquest::Engine::Error) { Sync { driver.run } }
    assert_match(/stream retry cap exhausted/, error.message)
    assert_equal 2, rig[:governor].cap_for(:stream)
    salvage_lines = rig[:ledger].sink.blobs.values.join.split("\n")
                                .map { |l| JSON.parse(l) rescue nil }.compact
                                .count { |r| r["type"] == "salvage" }
    assert_equal 3, salvage_lines, "every salvage persisted as audit"
  end

  # FM-23 — the embed-call failure classes map to the SHARED classes +
  # `engine.embed_retry_cap`; resume idempotence stays the job-row's (J-IDEM,
  # unchanged — the governor never touches embed_jobs).
  def test_FM23_embed_failures_map_to_the_shared_classes_and_embed_cap
    governor = Kquest::Engine::RetryGovernor.new(conn: conn, config: @config, sleeper: ->(_) {})

    assert_equal :rate_limit, governor.class_for(Fast::Completions::RateLimitError.new(status: 429))
    assert_equal :server_error, governor.class_for(Fast::Completions::ServerError.new(status: 502))
    assert_equal :connection, governor.class_for(Fast::Completions::ConnectionError.new("ECONNREFUSED"))
    assert_equal :timeout, governor.class_for(Fast::Completions::TimeoutError.new("no data"))

    # the embed site reads the embed cap (site: :embed), the same shared classes
    assert_equal 3, governor.cap_for(:rate_limit, site: :embed)
    assert_equal 3, governor.cap_for(:timeout, site: :embed)
    assert_equal 5, governor.cap_for(:rate_limit, site: :llm), "the llm site keeps its own cap"

    # J-IDEM: the governor's embed-site retries never touch the job ledger
    before = conn[:embed_jobs].count
    tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = tenancy[:user_id]
    3.times do
      governor.retry!(:connection, session: {id: tenancy[:session_id]},
                      fingerprint: "fp-embed", seed: rand(1000), site: :embed)
    end
    assert_equal before, conn[:embed_jobs].count,
                 "resume idempotence stays the job-row's (J-IDEM) — the governor never writes embed_jobs"
  end

  # FM-03's complement: the governor REFUSES an identical (body, seed)
  # re-attempt (E-SEED's write-time guard).
  def test_governor_refuses_identical_body_seed_reattempt
    governor = Kquest::Engine::RetryGovernor.new(conn: conn, config: @config, sleeper: ->(_) {})
    tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = tenancy[:user_id]
    session = {id: tenancy[:session_id]}
    governor.retry!(:timeout, session: session, fingerprint: "same-body", seed: 42)

    error = assert_raises(Kquest::Engine::Error) do
      governor.retry!(:timeout, session: session, fingerprint: "same-body", seed: 42)
    end
    assert_match(/identical \(body, seed\) re-attempt/, error.message)
  end
end
