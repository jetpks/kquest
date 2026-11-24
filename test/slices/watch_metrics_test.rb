# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# The /metrics action (I07 §5 shape): AUTHENTICATED (403 JSON anonymous),
# the exposition text over the live DB (# HELP/# TYPE + labelled samples for
# the fixture ledger rows), and the frozen exclusion (capped_listing_overhang
# never lands).
class WatchMetricsTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  Owner = Struct.new(:id, :github_uid, :username, :name, :email, :avatar_url, keyword_init: true)

  def sign_in_owner
    row = conn[:users].where(id: @tenancy[:user_id]).first
    sign_in(Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                      name: row[:name], email: row[:email], avatar_url: row[:avatar_url]))
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def test_anonymous_request_is_403_json
    status, headers, body = get("/metrics")
    assert_equal 403, status
    assert_match "application/json", headers["content-type"]
    assert_equal JSON.parse(Array(body).join), {"error" => "Forbidden"}
  end

  def test_authenticated_metrics_scrape_renders_the_exposition_shape
    sign_in_owner

    # Fixture ledger rows (the metric formulas' inputs).
    session_id = conn[:sessions].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                        phase_id: conn[:phases].insert(
                                          user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                          kind: "decompose"
                                        ), mode: "autonomous", driver: "orchestrator",
                                        model: "test-model")
    conn[:tool_calls].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                             session_id: session_id, seq: 1, tool: "status",
                             args: Sequel.lit("'{}'::jsonb"), result: Sequel.lit("'{}'::jsonb"),
                             ok: false, error_class: "unknown_tool")

    status, headers, body = get("/metrics")
    assert_equal 200, status
    assert_match "text/plain", headers["content-type"]
    text = body.respond_to?(:join) ? body.join : body.to_s

    assert_includes text, "# HELP kquest_refusal_rate_session "
    assert_includes text, "# TYPE kquest_refusal_rate_session gauge"
    assert_match(/kquest_refusal_rate_session\{.*session_id="#{session_id}".*\} 1\.0/, text,
                 "the fixture refusal lands as a labelled sample")
    assert_includes text, "# TYPE kquest_refusal_class_census counter"
    assert_match(/error_class="unknown_tool"/, text)
  end

  def test_capped_listing_overhang_never_lands
    sign_in_owner
    status, _, body = get("/metrics")
    assert_equal 200, status
    text = body.respond_to?(:join) ? body.join : body.to_s
    refute_includes text, "capped_listing_overhang",
                    "I07 DR-05's deferral holds — no tool cap telemetry day one"
  end
end
