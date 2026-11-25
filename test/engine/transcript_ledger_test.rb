# frozen_string_literal: true

require_relative "../test_helper"
require "fast/completions"
require_relative "../support/pipeline_fixtures"
require_relative "../support/mock_completions_server"

# The TranscriptLedger — L8's verbatim transcript at the CHECK-law blob
# location (I04 §2.1). FM-13's ledger leg / FM-15's ledger leg land here.
# All keyless.
class TranscriptLedgerTest < Minitest::Test
  CHECK = "sessions/%s/transcript.jsonl" # the I01 CHECK law's shape

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @mock = MockCompletionsServer.new.start
    @tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
  end

  def teardown
    @mock&.stop
    PipelineFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  def engine(contract:, script:)
    cfg = Kquest::Engine::DEFAULT_CONFIG.transform_values { |v| {value: v, mode: "advisory"} }
    conn[:llm_providers].where(name: "ledger-test-provider").delete
    conn[:llm_providers].insert(name: "ledger-test-provider", base_url: @mock.url,
                                api_key_ref: nil, model_id: "engine-test-model",
                                context_window: 8192, max_tokens: 512, reasoning: false,
                                max_retries: 0)
    row = conn[:llm_providers].where(name: "ledger-test-provider").first
    session = {id: @tenancy[:session_id], user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
               phase_id: @tenancy[:phase_id], model: row[:model_id]}
    @session_id = session[:id]
    desk = Kquest::Engine::ProviderDesk.new(conn: conn, provider_row: row, session: session)
    ledger = Kquest::Engine::TranscriptLedger.new(conn: conn, session: session)
    budgeter = Kquest::Engine::ContextBudgeter.new(conn: conn, session: session, desk: desk, config: cfg)
    supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn)
    supervisor.live_sessions.add(session[:id])
    governor = Kquest::Engine::RetryGovernor.new(conn: conn, config: cfg, supervisor: supervisor,
                                                 sleeper: ->(_) {})
    harness = Kquest::Engine::ToolHarness.new(conn: conn, session: session, ledger: ledger, config: cfg)
    driver = Kquest::Engine::LoopDriver.new(conn: conn, desk: desk, harness: harness, ledger: ledger,
                                            budgeter: budgeter, watch: nil, governor: governor,
                                            supervisor: supervisor, contract: contract,
                                            config: cfg, tools: [])
    @mock.script(script)
    [driver, {desk: desk, ledger: ledger, session: session, supervisor: supervisor}]
  end

  def salvage_lines(ledger)
    ledger.sink.blobs.values.join.split("\n")
         .map { |l| JSON.parse(l) rescue nil }.compact
         .select { |r| r["type"] == "salvage" }
  end

  def json_lines(ledger)
    ledger.sink.blobs.values.join.split("\n")
         .map { |l| JSON.parse(l) rescue nil }.compact
  end

  # The layout law: the ledger's blob location satisfies the frozen I01 CHECK
  # (`^sessions/<uuid>/transcript\.jsonl$`) — schema-beats-prose, and the
  # session row CARRIES the key.
  def test_transcript_blob_key_satisfies_the_i01_check
    contract = Object.new
    contract.define_singleton_method(:assemble_context) { |_t| {instructions: "i", messages: []} }
    contract.define_singleton_method(:terminal?) { |turn:, chat:| turn >= 1 && chat.complete? }
    contract.define_singleton_method(:max_turns) { 1 }
    driver, rig = engine(contract: contract, script: [{type: :text, content: "hello"}])

    assert_equal format(CHECK, @session_id), rig[:ledger].location
    Sync { driver.run }

    key = conn[:sessions].where(id: @session_id).get(:transcript_blob_key)
    assert_match(/\Asessions\/[0-9a-f-]{36}\/transcript\.jsonl\z/, key)
    assert_operator rig[:ledger].bytes, :>, 0, "the transcript blob is non-empty"
  end

  # FM-13 ledger leg: the salvaged partial persists as audit (its own line
  # type), never auto-appended to the live history.
  def test_FM13_salvaged_partial_persists_as_audit_not_live_history
    contract = Object.new
    contract.define_singleton_method(:assemble_context) { |_t| {instructions: "i", messages: []} }
    contract.define_singleton_method(:terminal?) { |**_| false }
    contract.define_singleton_method(:max_turns) { 2 }
    driver, rig = engine(contract: contract, script: [{type: :missing_finish},
                                                      {type: :text, content: "next turn"}])

    Sync { driver.run }

    salvage = salvage_lines(rig[:ledger]).first
    refute_nil salvage
    assert_equal 18, salvage.dig("message", "usage", "total_tokens"), "the salvage carries its usage"
    finals = json_lines(rig[:ledger]).select { |r| r["type"] == "final" }
    finals.each do |final|
      content = final.dig("message", "content")
      refute content&.any? { |b| b.is_a?(Hash) && b["text"] == "partial" },
             "the salvaged partial is NEVER appended to the live history"
    end
  end

  # FM-15 ledger leg: a mid-stream failure's salvaged partial AND its usage
  # persist; the turn retries with a fresh seed.
  def test_FM15_abort_mid_stream_salvage_persists_and_retry_carries_fresh_seed
    contract = Object.new
    contract.define_singleton_method(:assemble_context) { |_t| {instructions: "i", messages: []} }
    contract.define_singleton_method(:terminal?) { |**_| false }
    contract.define_singleton_method(:max_turns) { 2 }
    driver, rig = engine(contract: contract, script: [{type: :abort_mid_stream},
                                                      {type: :text, content: "recovered"}])

    Sync { driver.run }

    salvage = salvage_lines(rig[:ledger]).first
    refute_nil salvage, "the abort's salvaged partial persisted as audit"
    assert_equal 18, salvage.dig("message", "usage", "total_tokens")
    seeds = @mock.captured_requests.map { |b| b["seed"] }
    refute_equal seeds[0], seeds[1], "the retry carries a fresh seed (E-SEED)"
  end

  # The cancelled turn appends NOTHING (FM-19: no phantom terminal).
  def test_cancelled_turn_appends_nothing
    contract = Object.new
    contract.define_singleton_method(:assemble_context) { |_t| {instructions: "i", messages: []} }
    contract.define_singleton_method(:terminal?) { |**_| false }
    contract.define_singleton_method(:max_turns) { 1 }
    driver, rig = engine(contract: contract, script: [{type: :slow_ttfb, delay: 10}])
    ledger = rig[:ledger]
    chat = driver.chat

    Sync do
      task = Async do |parent|
        parent.async do
          sleep 0.3
          rig[:supervisor].cancel_now!(chat)
        end
        driver.run_turn(0) # the CancelledError surfaces as :paused
      end
      task.wait
    end

    assert_equal 0, ledger.bytes, "the half-streamed turn was never appended"
    assert_equal [], json_lines(ledger).select { |r| %w[final salvage].include?(r["type"]) },
                 "no phantom terminal line"
  end

  # I18 (the §8 amendment): the operator turn's transcript line — ONE
  # `{type: "operator", body: …}` JSONL line, its own write (buffered +
  # flushed), landed by the WORKER at consume time; the blob's location/sink
  # law unchanged; the line joins the L8 verbatim record the briefing
  # exchange rebuilds the conversation from.
  def test_append_operator_lands_one_operator_line_and_flushes
    ledger = Kquest::Engine::TranscriptLedger.new(
      conn: conn,
      session: {id: @tenancy[:session_id], user_id: @user_id, quest_id: @tenancy[:quest_id],
                phase_id: @tenancy[:phase_id], model: "test-model"}
    )

    Sync do
      ledger.append_operator!(body: "steer the decomposition toward decay studies")
      ledger.append_operator!(body: "second operator turn")
    end

    lines = ledger.sink.blobs.values.join.split("\n")
    parsed = lines.map { |l| JSON.parse(l) }
    assert_equal 2, parsed.size, "exactly one line per append_operator! — nothing else"
    assert_equal({"type" => "operator", "body" => "steer the decomposition toward decay studies"},
                 parsed[0])
    assert_equal({"type" => "operator", "body" => "second operator turn"}, parsed[1])
    assert_operator ledger.bytes, :>, 0, "the append flushed to the blob (buffer emptied)"
    assert_equal format(CHECK, @tenancy[:session_id]), ledger.location,
                 "the operator line rides the session's own blob (location law unchanged)"
  end
end
