# frozen_string_literal: true

require_relative "../test_helper"
require "fast/completions"
require_relative "../support/pipeline_fixtures"
require_relative "../support/mock_completions_server"

# StreamWatch — the telemetry/growth consumer (I04 §2.1). FM-14 / FM-18 land
# here; the tripwire PREDICATES over the recorded counts are ENTRY 4/I07's
# and are deliberately absent. All keyless.
class StreamWatchTest < Minitest::Test
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

  def config(overrides = {})
    Kquest::Engine::DEFAULT_CONFIG.transform_values { |v| {value: v, mode: "advisory"} }
                                 .merge(overrides.transform_values { |v| {value: v, mode: "advisory"} })
  end

  def watch(config_overrides = {}, pause_callback: nil)
    Kquest::Engine::StreamWatch.new(conn: conn, session: {id: @tenancy[:session_id]},
                                    config: config(config_overrides), pause_callback: pause_callback)
  end

  # FM-14 — `:bad_chunk`: dropped chunks are COUNTED (the gem tolerates; the
  # loop never re-adds strictness), recorded per session, alert at threshold;
  # the turn does NOT fail for a chunk the gem tolerated.
  def test_FM14_bad_chunk_counted_and_alerted_but_the_turn_survives
    @mock.script([{type: :bad_chunk}, {type: :bad_chunk}, {type: :bad_chunk}])
    conn[:llm_providers].where(name: "watch-provider").delete
    conn[:llm_providers].insert(name: "watch-provider", base_url: @mock.url, api_key_ref: nil,
                                model_id: "engine-test-model", context_window: 8192,
                                max_tokens: 512, reasoning: false, max_retries: 0)
    row = conn[:llm_providers].where(name: "watch-provider").first
    session = {id: @tenancy[:session_id], user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
               phase_id: @tenancy[:phase_id], model: row[:model_id]}
    w = watch
    desk = Kquest::Engine::ProviderDesk.new(conn: conn, provider_row: row, session: session, watch: w)
    chat = Fast::Completions::Chat.new(client: desk.client, model: desk.model)
    chat.with_instructions("i")

    Sync do
      3.times do
        chat.step # :bad_chunk — each turn completes naturally
        w.observe_client!(desk.client) # the per-session record (the driver calls this per turn)
      end
    end

    assert_equal 3, w.dropped_chunks, "the malformed chunks were dropped + counted, never raised"
    assert_equal 3, chat.messages.size, "the turns did NOT fail (tolerant inbound stream)"
    assert_equal "tolerated stream", chat.messages.first.content.first[:text],
                 "the dropped chunk lost no tolerated text"
    alert = w.signals.find { |s| s[:type] == :dropped_chunks }
    refute_nil alert, "the dropped_chunk_alert_threshold (3) alert fired"
    assert_match(/serving-stack health signal/, alert[:message])
    assert_match(/FM-13|FM-11/, alert[:message], "the residual risks are named")
  ensure
    desk&.close
  end

  # FM-18 — SLOWSTALL: growth < slow_stall_bytes over the window while
  # running → ALERT ONLY carrying the never-kill rule; the unattended window
  # elapsing → pause, never kill.
  def test_FM18_slowstall_alerts_only_and_the_unattended_window_pauses_never_kills
    paused = false
    w = watch({"engine.slow_stall_bytes" => 100,
               "engine.slow_stall_window_s" => 10,
               "engine.unattended_pause_s" => 20},
              pause_callback: -> { paused = true })

    t0 = Time.now
    # a healthy sample, then a stalled one: 50B over the 10s window (< 100B)
    w.observe_transcript!(100_000, at: t0)
    assert w.signals.empty?

    w.observe_transcript!(100_050, at: t0 + 11)
    alert = w.signals.find { |s| s[:type] == :slow_stall }
    refute_nil alert, "the SLOWSTALL alert fired"
    assert_match(/ALERT ONLY/, alert[:message])
    assert_match(/NOT to be killed on this signal alone/, alert[:message], "the never-kill rule is IN the alert")
    assert_equal false, paused, "the SLOWSTALL alert alone NEVER kills or pauses"

    # the unattended window elapses → PAUSE (the callback), never a kill
    w.observe_transcript!(100_050, at: t0 + 31)
    pause_signal = w.signals.find { |s| s[:type] == :unattended_pause }
    refute_nil pause_signal
    assert_equal true, paused, "the unattended window paused the quest (never killed)"
    assert_match(/pause, never kill/, pause_signal[:message])
  end

  # The empty-completion storm: recorded COUNTS only (the predicates are
  # ENTRY 4/I07's).
  def test_empty_completions_are_counted_not_enforced
    w = watch
    message = Fast::Completions::Message.assistant([])
    Sync do
      2.times { w.on_completion_end(:stop, 0.1, message) }
      w.on_completion_end(:tool_use, 0.1, Fast::Completions::Message.assistant([{type: :tool_call,
        id: "c", name: "n", arguments: {}}]))
    end
    assert_equal 2, w.empty_completions
    assert_equal 2, w.signals.count { |s| s[:type] == :empty_completion_storm },
                 "recorded counts only — the storm PREDICATE is ENTRY 4/I07's"
  end
end
