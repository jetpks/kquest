# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/orchestrator/metrics"

# The /metrics exposition renderer (I07 §5 shape): `# HELP`/`# TYPE` headers
# + labelled samples computed as VIEWS over the durable ledgers (no second
# bookkeeping), keyless-unit-tested against fixture ledger rows — the exact
# exposition text is the assertion.
class MetricsTest < Minitest::Test
  def setup
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    @quest_id = @tenancy[:quest_id]
  end

  def teardown
    OrchestratorFixtures.cleanup(conn, user_id: @user_id)
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def exposition
    @exposition ||= Kquest::Orchestrator::Metrics.render(conn, user_id: @user_id)
  end

  def mint_fixture_ledgers
    phase_id = conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "decompose",
                                    state: "complete", started_at: Time.now,
                                    ended_at: Time.now, frontier_open: 3, frontier_mass: 21)
    session_id = conn[:sessions].insert(user_id: @user_id, quest_id: @quest_id,
                                        phase_id: phase_id, mode: "autonomous",
                                        driver: "orchestrator", model: "test-model")
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id, session_id: session_id,
                             seq: 1, tool: "status", args: Sequel.lit("'{}'::jsonb"),
                             result: Sequel.lit("'{}'::jsonb"), ok: false,
                             error_class: "unknown_tool")
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id, session_id: session_id,
                             seq: 2, tool: "mass", args: Sequel.lit("'{}'::jsonb"),
                             result: Sequel.lit("'{}'::jsonb"), ok: true)
    conn[:usage_events].insert(user_id: @user_id, quest_id: @quest_id, phase_id: phase_id,
                               session_id: session_id, kind: "llm", model: "test-model",
                               input_tokens: 100, output_tokens: 50, cost_usd: BigDecimal("0.5"))
    {phase_id: phase_id, session_id: session_id}
  end

  def test_exposition_carries_help_and_type_headers_with_labelled_samples
    ids = mint_fixture_ledgers
    text = exposition

    assert_includes text, "# HELP kquest_refusal_rate_session "
    assert_includes text, "# TYPE kquest_refusal_rate_session gauge"
    assert_includes text,
                    %(kquest_refusal_rate_session{quest_id="#{@quest_id}",session_id="#{ids[:session_id]}",user_id="#{@user_id}"} 0.5)
    assert_includes text, "# TYPE kquest_refusal_class_census counter"
    assert_includes text, %(error_class="unknown_tool"} 1)
    assert_includes text, "# TYPE kquest_spend counter"
    assert_includes text, %(kind="cost_usd"} 0.5)
    assert_includes text, "# TYPE kquest_mass_curve gauge"
    assert_includes text, %(kquest_mass_curve{quest_id="#{@quest_id}",phase_id="#{ids[:phase_id]}")
  end

  def test_the_blind_spot_day_one_four_render_and_overhang_never_lands
    OrchestratorFixtures.mint_source(conn, user_id: @user_id, quest_id: @quest_id,
                                     snapshot: "staged and unmined fixture text")
    text = exposition

    assert_includes text, "# HELP kquest_unmined_citable "
    assert_match(/kquest_unmined_citable\{quest_id="#{@quest_id}"\} 1/, text)
    assert_includes text, "kquest_fetched_never_cited"
    assert_includes text, "kquest_uncited_claims"
    assert_includes text, "kquest_aging_open_needs"
    refute_includes text, "capped_listing_overhang",
                    "I07 DR-05's deferral holds — the family does NOT land day one"
  end

  def test_metabolism_carries_the_r018_ratio_axes
    snapshot = "the fixture corpus"
    source = OrchestratorFixtures.mint_source(conn, user_id: @user_id, quest_id: @quest_id,
                                              snapshot: snapshot)
    conn[:evidence].insert(user_id: @user_id, quest_id: @quest_id,
                           source_id: source[:id], source_anchorable: true,
                           snapshot_char_count: snapshot.length,
                           span_start: 0, span_end: 3, span_text: "the",
                           reading: "the fixture reading")
    text = exposition

    assert_includes text, "# HELP kquest_metabolism "
    assert_match(/ratio="evidence_per_source"\} 1\.0/, text)
    assert_match(/ratio="claims_per_source"\} 0\.0/, text)
  end

  def test_tripwire_fires_counts_the_live_predicate_rows
    # A fired predicate (a session silent past the stall window) shows up as
    # a labelled sample; the renderer is a VIEW over the views.
    session = conn[:sessions].insert(user_id: @user_id, quest_id: @quest_id,
                                     phase_id: conn[:phases].insert(user_id: @user_id,
                                                                    quest_id: @quest_id,
                                                                    kind: "decompose"),
                                     mode: "autonomous", driver: "orchestrator",
                                     model: "test-model", started_at: Time.now - 1300)
    text = exposition
    assert_match(/kquest_tripwire_fires\{predicate="tw_wedge"\} 1/, text)
  ensure
    conn[:sessions].where(id: session).delete if session
    conn[:phases].where(quest_id: @quest_id).delete
  end
end
