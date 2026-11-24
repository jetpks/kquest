# frozen_string_literal: true

require_relative "../test_helper"
require "fast/completions"
require_relative "../support/pipeline_fixtures"
require_relative "../support/mock_completions_server"

# The SpendRecorder — the telemetry-sink call-site recorder (I04 §9).
# FM-15's spend leg / FM-25 / E-SPEND land here. All keyless.
class SpendRecorderTest < Minitest::Test
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

  def desk(provider_overrides = {})
    conn[:llm_providers].where(name: "spend-test-provider").delete
    conn[:llm_providers].insert(name: "spend-test-provider", base_url: @mock.url,
                                api_key_ref: nil, model_id: "engine-test-model",
                                context_window: 8192, max_tokens: 512, reasoning: false,
                                max_retries: 0, **provider_overrides)
    row = conn[:llm_providers].where(name: "spend-test-provider").first
    session = {id: @tenancy[:session_id], user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
               phase_id: @tenancy[:phase_id], model: row[:model_id]}
    Kquest::Engine::ProviderDesk.new(conn: conn, provider_row: row, session: session)
  end

  def rows = conn[:usage_events].where(session_id: @tenancy[:session_id], kind: "llm").all

  # FM-25 — one usage_events row per completion, success XOR error
  # structurally; failures record zero-token rows.
  def test_FM25_one_row_per_completion_success_xor_error_structurally
    @mock.script([{type: :text, content: "ok"}, {type: :status, status: 503, message: "down"}])
    the_desk = desk
    chat = Fast::Completions::Chat.new(client: the_desk.client, model: the_desk.model)

    Sync do
      chat.with_instructions("i")
      chat.step
      begin
        chat.step
      rescue Fast::Completions::ServerError
        nil # the failed completion still lands its row
      end
      the_desk.spend.flush!
    end

    assert_equal 2, rows.size
    success, failure = rows.sort_by { |r| r[:input_tokens] }.reverse
    assert_equal 11, success[:input_tokens]
    assert_equal 7, success[:output_tokens]
    assert_equal 0, failure[:input_tokens], "the failed call records a zero-token row"
    assert_equal 0, failure[:output_tokens]
    assert_equal "engine-test-model", success[:model] # sessions.model parity — never a prompt echo
  ensure
    the_desk&.close
  end

  # FM-25 — nil usage records a zero-row (the honesty marker for a dialect
  # that cannot report usage, FM-25's supports_usage_in_streaming arm).
  def test_FM25_nil_usage_records_a_zero_row
    the_desk = desk
    chat = Fast::Completions::Chat.new(client: the_desk.client, model: the_desk.model)
    recorder = the_desk.spend
    message = Fast::Completions::Message.assistant([{type: :text, text: "x"}]) # no usage carried

    Sync do
      recorder.on_completion_start("m", 100)
      recorder.on_completion_end(:stop, 0.1, message)
      recorder.flush!
    end

    row = rows.first
    refute_nil row
    assert_equal 0, row[:input_tokens]
    assert_equal 0, row[:output_tokens]
  ensure
    the_desk&.close
  end

  # FM-25 — a double-terminal violates the sink and RAISES (the terminal
  # invariant asserted by the consumer).
  def test_FM25_double_terminal_violates_the_sink_and_raises
    the_desk = desk
    recorder = the_desk.spend
    Sync do
      recorder.on_completion_start("m", 100)
      recorder.on_completion_end(:stop, 0.1, nil)
      error = assert_raises(Kquest::Engine::Error) do
        recorder.on_completion_error(:stream_error, 0.2)
      end
      assert_match(/terminal invariant violated/, error.message)
    end
  ensure
    the_desk&.close
  end

  # FM-15 — a mid-stream failure's SALVAGED usage is the row (the only
  # recoverable mid-turn tokens; tokens were spent).
  def test_FM15_salvaged_partial_usage_persists_as_the_row
    @mock.script([{type: :abort_mid_stream}])
    the_desk = desk
    chat = Fast::Completions::Chat.new(client: the_desk.client, model: the_desk.model)

    Sync do
      begin
        chat.with_instructions("i")
        chat.step
      rescue Fast::Completions::ConnectionError
        nil
      end
      the_desk.spend.flush!
    end

    assert_equal 1, rows.size
    row = rows.first
    assert_equal 11, row[:input_tokens], "the salvaged partial's usage"
    assert_equal 7, row[:output_tokens]
  ensure
    the_desk&.close
  end

  # E-SPEND — the seed echo column: the row's seed is the decorator's SERVED
  # seed (replay diagnosis is a query; DR-12's landed column).
  def test_E_SPEND_the_row_carries_the_served_seed
    @mock.script([{type: :text, content: "seeded"}])
    the_desk = desk
    chat = Fast::Completions::Chat.new(client: the_desk.client, model: the_desk.model)

    Sync do
      chat.with_instructions("i")
      chat.step
      the_desk.spend.flush!
    end

    served = the_desk.client.last_served_seed
    refute_nil served
    assert_equal served, rows.first[:seed]
    assert_equal 0, rows.first[:cost_usd].to_f, "NULL pricing = a local engine (D10)"
  ensure
    the_desk&.close
  end

  # D10 — priced provider rows compute cost_usd from the DR-12 token columns
  # (usage_events.cost_usd is numeric(12,6) — the mock's 11/7-token completions
  # price above the scale so the arithmetic is observable).
  def test_cost_computed_from_the_provider_rows_pricing
    @mock.script([{type: :text, content: "priced"}])
    the_desk = desk(cost_per_mtok_in: 150.0, cost_per_mtok_out: 600.0)
    chat = Fast::Completions::Chat.new(client: the_desk.client, model: the_desk.model)

    Sync do
      chat.with_instructions("i")
      chat.step
      the_desk.spend.flush!
    end

    row = rows.first
    expected = (BigDecimal(11) * BigDecimal("150") + BigDecimal(7) * BigDecimal("600")) / 1_000_000
    assert_in_delta expected.to_f, Float(row[:cost_usd]), 1e-9
  ensure
    the_desk&.close
  end
end
