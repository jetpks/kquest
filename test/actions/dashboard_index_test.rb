# frozen_string_literal: true

require_relative "action_test_helper"
require_relative "../support/orchestrator_fixtures"

# The dashboard IS the root (I16 Part 3, Grounds §8): the three carried home
# assertions — component `Dashboard/Index` (page object + x-inertia headers),
# the anonymous shared props, the signed-in shared props — live here; Home
# retired. Anonymous renders a 200 SIGN-IN PROMPT CARD, never a redirect
# (the loop hazard: require_login → "/" → dashboard → "/").
class DashboardIndexTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    seed_listing_cap("dashboard", 50)
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  # The cap rows are test data (the landed cleanup wipes tool_config; the
  # seeds' delete+insert law re-heals at the next prepare — every consumer
  # upserts its own rows, the standing law).
  def seed_listing_cap(surface, cap)
    key = "ui.listing_cap.#{surface}"
    conn[:tool_config].where(key: key).delete
    conn[:tool_config].insert(key: key, num_value: cap, text_value: nil,
                              provenance: "test data (the seeds re-heal at the next prepare)")
  end

  Owner = Struct.new(:id, :github_uid, :username, :name, :email, :avatar_url, keyword_init: true)

  def sign_in_as_owner
    row = conn[:users].where(id: @tenancy[:user_id]).first
    user = Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                     name: row[:name], email: row[:email], avatar_url: row[:avatar_url])
    sign_in(user)
    user
  end

  def test_root_renders_dashboard_index_page_object
    status, headers, body = inertia_get("/")
    assert_equal 200, status
    assert_equal "true", headers["x-inertia"]
    assert_equal "application/json", headers["content-type"]

    data = parse_json(body)
    assert_equal "Dashboard/Index", data["component"]
    assert_equal "/", data["url"]
    assert data.key?("version")
  end

  def test_root_carries_shared_props_for_anonymous
    _, _, body = inertia_get("/")
    props = parse_json(body)["props"]
    assert_nil props["current_user"]
    assert_equal({}, props["flash"])
  end

  def test_root_shared_props_carry_signed_in_user
    user = sign_in_as_owner
    _, _, body = inertia_get("/")
    assert_equal user.username, parse_json(body)["props"]["current_user"]["username"]
  end

  def test_anonymous_is_200_never_a_redirect
    status, headers, = get("/")
    assert_equal 200, status, "anonymous root is a 200 sign-in prompt card"
    assert_nil headers["location"], "a redirect here would loop (the Grounds §8 hazard)"
  end

  def test_signed_in_props_carry_the_capped_quest_cards
    sign_in_as_owner
    _, _, body = inertia_get("/")
    props = parse_json(body)["props"]
    assert_equal 1, props["quests"]["rows"].size
    assert_equal @tenancy[:quest_id], props["quests"]["rows"].first["id"]
    assert_equal 50, props["quests"]["cap"], "the cap comes from ui.listing_cap.dashboard"
    assert props.key?("blind_spots"), "the blind-spot panel is present"
    assert props.key?("overhang"), "the overhang join is present"
    assert_equal "/alerts/stream", props["stream_url"]
  end

  def test_the_overhang_join_reflects_cap_records
    sign_in_as_owner
    Kquest::Ui::CapRecords.record!(conn, user_id: @tenancy[:user_id], surface: "frontier",
                                   requested: 80, cap: 50, existed: 80)
    _, _, body = inertia_get("/")
    row = parse_json(body)["props"]["overhang"].find { |r| r["surface"] == "frontier" }
    assert_equal 30, row["overhang"]
  ensure
    conn[:cap_records].where(user_id: @tenancy[:user_id]).delete
  end

  def test_a_cap_records_row_is_written_per_dashboard_view
    sign_in_as_owner
    inertia_get("/")
    rows = conn[:cap_records].where(user_id: @tenancy[:user_id], surface: "dashboard")
    assert_equal 1, rows.count, "one telemetry row per capped listing request"
  end
end
