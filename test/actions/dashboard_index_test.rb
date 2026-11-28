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
    # The I19 tables are NOT in the landed sweeps — reverse-FK order:
    # grants → members → workspaces → cleanup.
    conn[:resource_grants].delete
    conn[:workspace_members].delete
    conn[:workspaces].delete
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
    OrchestratorFixtures.cleanup(conn, user_id: @mate_id) if @mate_id
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

  # ── the I19 workspace-admin props (Spec Part 3): the FOUR capped lists
  #    ride the ONE surface `workspace_admin` ─────────────────────────────

  def mint_workspace_admin_fixtures!
    @workspace_id = conn[:workspaces].insert(name: "ws-props-01",
                                             created_by_user_id: @tenancy[:user_id])
    conn[:workspace_members].insert(workspace_id: @workspace_id,
                                    user_id: @tenancy[:user_id])
    @mate_id = conn[:users].insert(handle: "gh-mate-#{SecureRandom.hex(4)}",
                                   github_uid: SecureRandom.uuid,
                                   username: "u#{SecureRandom.hex(6)}",
                                   name: "Mate", created_at: Time.now)
    conn[:workspace_members].insert(workspace_id: @workspace_id, user_id: @mate_id)
    @source = OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                               quest_id: @tenancy[:quest_id],
                                               snapshot: "dashboard props text")
    @public_grant_id = conn[:resource_grants].insert(
      owner_user_id: @tenancy[:user_id], source_id: @source[:id], is_public: true,
      note: "the public note", granted_at: Time.now - 60
    )
    @ws_grant_id = conn[:resource_grants].insert(
      owner_user_id: @tenancy[:user_id], source_id: @source[:id],
      grantee_workspace_id: @workspace_id, note: "the workspace note", granted_at: Time.now
    )
  end

  def test_workspace_admin_props_carry_the_four_capped_lists
    seed_listing_cap("workspace_admin", 2)
    mint_workspace_admin_fixtures!
    sign_in_as_owner
    _, _, body = inertia_get("/")
    ws = parse_json(body)["props"]["workspaces"]

    assert_equal %w[grants members memberships owned], ws.keys.sort,
                 "the section's FOUR lists"

    owned = ws["owned"]
    assert_equal 1, owned["rows"].size
    assert_equal ["created_at", "id", "name"], owned["rows"].first.keys.sort
    assert_equal "ws-props-01", owned["rows"].first["name"]
    assert_equal 2, owned["cap"], "the cap comes from ui.listing_cap.workspace_admin"

    members = ws["members"]["rows"]
    assert_equal 2, members.size, "the OWNED workspaces' members, joined to users"
    assert_equal ["handle", "joined_at", "user_id", "workspace_id", "workspace_name"],
                 members.first.keys.sort
    assert_equal "ws-props-01", members.first["workspace_name"]
    assert_includes members.map { |r| r["handle"] }, conn[:users].where(id: @mate_id).get(:handle)

    memberships = ws["memberships"]["rows"]
    assert_equal 1, memberships.size, "MY memberships joined to workspaces (read-only display)"
    assert_equal ["joined_at", "workspace_id", "workspace_name"],
                 memberships.first.keys.sort
    assert_equal "ws-props-01", memberships.first["workspace_name"]
  ensure
    conn[:resource_grants].delete
    conn[:workspace_members].delete
    conn[:workspaces].delete
    conn[:cap_records].where(user_id: @tenancy[:user_id]).delete
  end

  def test_workspace_admin_grants_rows_carry_the_join_display_fields
    seed_listing_cap("workspace_admin", 50)
    mint_workspace_admin_fixtures!
    sign_in_as_owner
    _, _, body = inertia_get("/")
    grants = parse_json(body)["props"]["workspaces"]["grants"]["rows"]
    assert_equal 2, grants.size
    assert_equal @ws_grant_id, grants.first["id"],
                 "granted_at DESC — the newer workspace grant first"
    assert_equal "ws-props-01", grants.first["workspace_name"]
    assert_equal "the workspace note", grants.first["note"]
    assert_equal @source[:urn], grants.first["source_urn"], "the urn join"
    assert_equal "Fixture source", grants.first["source_title"], "the title join"
    refute_nil grants.first["granted_at"], "the when-carrier renders"

    public_row = grants.last
    assert_equal true, public_row["is_public"]
    assert_nil public_row["workspace_name"],
                 "a public grant's grantee columns are NULL — the LEFT join keeps the row"
    assert_nil public_row["grantee_handle"]
    assert_equal "the public note", public_row["note"]
  ensure
    conn[:resource_grants].delete
    conn[:workspace_members].delete
    conn[:workspaces].delete
    conn[:cap_records].where(user_id: @tenancy[:user_id]).delete
  end
end
