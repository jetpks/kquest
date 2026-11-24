# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# GET /alerts — the alerting surface (I16 Part 2): the 13 tw_* fire sets
# (SELECT-only over the poller's own views), the REUSED Metrics panels, the
# per-quest stream links, capped listings, and the visibility posture. No
# enforcement anywhere.
class WatchAlertsIndexTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    seed_listing_cap("alerts", 20)
    sign_in_as_owner
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  Owner = Struct.new(:id, :github_uid, :username, :name, :email, :avatar_url, keyword_init: true)

  def sign_in_as_owner
    row = conn[:users].where(id: @tenancy[:user_id]).first
    user = Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                     name: row[:name], email: row[:email], avatar_url: row[:avatar_url])
    sign_in(user)
    user
  end

  def seed_listing_cap(surface, cap)
    key = "ui.listing_cap.#{surface}"
    conn[:tool_config].where(key: key).delete
    conn[:tool_config].insert(key: key, num_value: cap, text_value: nil,
                              provenance: "test data (the seeds re-heal at the next prepare)")
  end

  # tw_wedge fires on a still-live session whose ledger has been silent for
  # longer than the stall window (the view's own detection semantics).
  def mint_wedge_fire
    phase_id = conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    kind: "descent")
    conn[:sessions].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                           phase_id: phase_id, mode: "autonomous", driver: "orchestrator",
                           model: "test-model", started_at: Time.now - (2 * 3600))
  end

  def test_owner_renders_the_alerts_page_object_with_all_13_predicates
    status, _, body = inertia_get("/alerts")
    assert_equal 200, status
    props = parse_json(body)["props"]
    assert_equal "Alerts/Index", parse_json(body)["component"]
    predicates = props["fire_sets"].map { |fs| fs["predicate"] }
    assert_equal %w[tw_wedge tw_cache_wall tw_churn tw_context_blowout tw_empty_storm
                    tw_fingerprint_drift tw_hub_divergence tw_missing_spend tw_repetition
                    tw_rotation tw_shape_storm tw_size_ceiling tw_slowstall].sort, predicates.sort
  end

  def test_fire_sets_are_select_only_over_the_pollers_views
    mint_wedge_fire
    _, _, body = inertia_get("/alerts")
    wedge = parse_json(body)["props"]["fire_sets"].find { |fs| fs["predicate"] == "tw_wedge" }
    assert_equal 1, wedge["listing"]["rows"].size, "the fire set is the view's current set"
    assert_equal @tenancy[:quest_id], wedge["listing"]["rows"].first["quest_id"]
    assert_equal 1, wedge["listing"]["requested"]
  end

  def test_metrics_panels_are_the_reused_families
    mint_wedge_fire
    _, _, body = inertia_get("/alerts")
    names = parse_json(body)["props"]["metrics_panels"].map { |f| f["name"] }
    assert_includes names, "kquest_refusal_rate_session"
    assert_includes names, "kquest_refusal_class_census"
    assert_includes names, "kquest_transcript_audit_bytes"
    assert_includes names, "kquest_tripwire_fires"
    assert_includes names, "kquest_mass_curve"
  end

  def test_listings_are_capped_with_telemetry
    mint_wedge_fire
    _, _, body = inertia_get("/alerts")
    quests = parse_json(body)["props"]["quests"]
    assert_equal @tenancy[:quest_id], quests["rows"].first["id"]
    telemetry = conn[:cap_records].where(user_id: @tenancy[:user_id], surface: "alerts")
    assert telemetry.count >= 1, "one telemetry row per capped listing request"
  end

  def test_mute_state_renders_read_only_and_day_one_is_empty
    _, _, body = inertia_get("/alerts")
    assert_empty parse_json(body)["props"]["mute_state"]
    conn[:tool_config].insert(key: "alerts.mute.tw_wedge.#{@tenancy[:quest_id]}",
                              text_value: "muted by the operator",
                              provenance: "test data")
    _, _, body = inertia_get("/alerts")
    state = parse_json(body)["props"]["mute_state"]
    assert_equal 1, state.size
    assert_equal "muted by the operator", state.first["text_value"]
  ensure
    conn[:tool_config].where(Sequel.like(:key, "alerts.mute.%")).delete
  end

  def test_stream_url_is_the_user_level_stream
    _, _, body = inertia_get("/alerts")
    assert_equal "/alerts/stream", parse_json(body)["props"]["stream_url"]
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = get("/alerts")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end
end
