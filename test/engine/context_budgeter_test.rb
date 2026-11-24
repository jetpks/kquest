# frozen_string_literal: true

require_relative "../test_helper"
require "fast/completions"
require_relative "../support/pipeline_fixtures"
require_relative "../support/mock_completions_server"

# The ContextBudgeter — per-session context accounting (I04 §7). FM-02's
# budgeter leg / FM-09 / FM-22 / FM-24 / E-CBUD / E-CEIL land here.
class ContextBudgeterTest < Minitest::Test
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

  def desk_with(provider_overrides = {})
    conn[:llm_providers].where(name: "budgeter-provider").delete
    conn[:llm_providers].insert(name: "budgeter-provider", base_url: @mock.url, api_key_ref: nil,
                                model_id: "engine-test-model", context_window: 8192,
                                max_tokens: 512, reasoning: false,
                                transcript_ceiling_warn_bytes: 450_000,
                                transcript_ceiling_hard_bytes: 496_000, **provider_overrides)
    row = conn[:llm_providers].where(name: "budgeter-provider").first
    session = {id: @tenancy[:session_id], user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
               phase_id: @tenancy[:phase_id], model: row[:model_id]}
    Kquest::Engine::ProviderDesk.new(conn: conn, provider_row: row, session: session)
  end

  # overrides here are the FINAL line form ({key => {value:, mode:}})
  def budgeter(the_desk, overrides = {})
    Kquest::Engine::ContextBudgeter.new(conn: conn, session: {id: @tenancy[:session_id]},
                                        desk: the_desk, config: config.merge(overrides))
  end

  # FM-02 / E-CEIL — tiny ceilings: the warn band refuses NEW ingestion and
  # banks at the boundary; the hard band ends the session with the menu
  # record naming options A/B (the runtime operator decides — DR-06).
  def test_FM02_ceiling_bands_change_behavior_at_the_boundary # E-CEIL
    the_desk = desk_with(transcript_ceiling_warn_bytes: 1000, transcript_ceiling_hard_bytes: 2000)
    b = budgeter(the_desk)

    assert_equal :ok, b.ceiling_band
    b.record_transcript_bytes!(1500)
    assert_equal :warn, b.ceiling_band
    error = assert_raises(Kquest::Engine::Error) { b.tool_budget_check!("source_read") }
    assert_match(/new ingestion is refused/, error.message)
    assert_match(/never .*truncate a live transcript mid-flight/, error.message)

    b.record_transcript_bytes!(2500)
    assert_equal :hard, b.ceiling_band
    menu = b.ceiling_menu_record
    assert_equal ["A swap-at-the-wall", "B compact-and-continue"], menu[:options]
  end

  # FM-09 — the 400 context-overflow pattern: shrink + re-issue ONCE (fresh
  # seed), then bank at the boundary when unshrinkable.
  def test_FM09_shrink_once_then_bank
    the_desk = desk_with
    b = budgeter(the_desk)

    assert_equal :reissue_once, b.handle_context_error!
    b.record_shrunk!
    assert_equal :bank, b.handle_context_error!, "a SECOND overflow banks — never a loop"
  end

  # FM-22 / E-CBUD — oversized reads/results cross the accounting cap: the
  # ADVISORY line TEACHES (marks + reports, never silently truncates); a HARD
  # line changes behavior at the boundary.
  def test_FM22_read_slice_cap_advisory_marks_and_hard_refuses # E-CBUD
    the_desk = desk_with
    b = budgeter(the_desk) # advisory by default (DR-09)

    verdict = b.account_read!(9000) # cap 8000
    assert_equal :marked, verdict[:verdict]
    assert_match(/offset\/limit/, verdict[:note], "the teaching note names the slice form")

    hard = budgeter(the_desk, "engine.read_slice_cap_chars" => {value: 8000, mode: "hard"})
    # (config.merge above: the advisory default line is replaced by the hard one)
    verdict = hard.account_read!(9000)
    assert_equal :refused, verdict[:verdict], "a HARD line changes behavior at the boundary"
    assert_equal :ok, hard.account_read!(8000).fetch(:verdict)

    # the ingestion accounting: tool-result bytes recorded (the 78% lesson's
    # accounting half — the harness reports every result's size)
    before = b.ingested_bytes
    b.record_ingestion!("x" * 3000)
    assert_equal 3000, b.ingested_bytes - before
  end

  # FM-24 — the prefix-cache wall: cache_read = 0 at high context → the
  # cache-wall alert; the prompt prefix within a session stays append-only.
  def test_FM24_cache_wall_alert_and_the_append_only_prefix
    the_desk = desk_with(cache_wall_tokens: 205_000)
    b = budgeter(the_desk)

    b.observe_usage!(input_tokens: 260_000, cache_read_tokens: 0)
    alert = b.alerts.find { |a| a[:type] == "cache_wall" }
    refute_nil alert, "cache_read = 0 above the wall alerts"
    assert_match(/full re-prefill/, alert[:message])

    b.observe_usage!(input_tokens: 260_000, cache_read_tokens: 250_000)
    assert_equal 1, b.alerts.size, "cache hits above the wall do not alert"

    # append-only prefix law: a shrinking/rewritten prefix is a loud defect
    m1 = Fast::Completions::Message.user("one")
    m2 = Fast::Completions::Message.user("two")
    b.ensure_append_only!([m1], [m1, m2]) # growing is fine
    error = assert_raises(Kquest::Engine::Error) do
      b.ensure_append_only!([m1, m2], [m1, Fast::Completions::Message.user("rewritten")])
    end
    assert_match(/not append-only/, error.message)
  end

  # L10 — budgets read the LEDGER: the token rollup is a usage_events query,
  # never a stored counter.
  def test_token_rollup_reads_the_ledger
    the_desk = desk_with
    b = budgeter(the_desk)
    conn[:usage_events].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                               phase_id: @tenancy[:phase_id], session_id: @tenancy[:session_id],
                               kind: "llm", model: "engine-test-model", input_tokens: 100,
                               output_tokens: 20, cache_read_tokens: 5, cache_write_tokens: 3)
    assert_equal 128, b.token_rollup

    b.quest_token_budget = 128
    assert_equal true, b.budget_exhausted?
    b.quest_token_budget = 129
    assert_equal false, b.budget_exhausted?
  end
end
