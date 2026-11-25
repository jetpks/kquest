# frozen_string_literal: true

require_relative "action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /workspaces/:workspace_id/grants — grant to workspace (I19 Spec Part
# 2): the WORKSPACE owner gate first (granting into a workspace you cannot
# administer would bypass its owner's member list — 404 non-leak), then the
# door: the operator's OWN source by (urn, user_id) — the composite-FK X38
# class taught, never 500'd — REQUIRED note, duplicate taught.
class DashboardCreateWorkspaceGrantTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @workspace_id = conn[:workspaces].insert(name: "ws-grant-01",
                                             created_by_user_id: @tenancy[:user_id])
    @source = OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                               quest_id: @tenancy[:quest_id],
                                               snapshot: "grant action test text")
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    conn[:resource_grants].delete
    conn[:workspace_members].delete
    conn[:workspaces].delete
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
    OrchestratorFixtures.cleanup(conn, user_id: @other_user_id) if @other_user_id
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  Owner = Struct.new(:id, :github_uid, :username, :name, :email, :avatar_url, keyword_init: true)

  def sign_in_as_owner
    row = conn[:users].where(id: @tenancy[:user_id]).first
    sign_in(Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                      name: row[:name], email: row[:email], avatar_url: row[:avatar_url]))
  end

  def test_anonymous_is_redirected_to_sign_in_never_a_write
    status, headers, = post("/workspaces/#{@workspace_id}/grants",
                            params: {source_urn: @source[:urn], note: "n"})
    assert_equal 302, status
    assert_equal "/", headers["location"]
    assert_empty conn[:resource_grants].to_a
  end

  def test_non_owner_or_absent_workspace_is_404_json_before_any_mutation
    sign_in_as_owner
    other = conn[:users].insert(handle: "gh-other-#{SecureRandom.hex(4)}",
                                github_uid: SecureRandom.uuid,
                                username: "u#{SecureRandom.hex(6)}",
                                name: "Other", created_at: Time.now)
    other_ws = conn[:workspaces].insert(name: "ws-grant-other", created_by_user_id: other)

    status, headers, body = post("/workspaces/#{other_ws}/grants",
                                 params: {source_urn: @source[:urn], note: "n"})
    assert_equal 404, status
    assert_match "application/json", headers["content-type"]
    assert_equal JSON.parse(Array(body).join), {"error" => "Not found"}
    status, _, _ = post("/workspaces/#{SecureRandom.uuid}/grants",
                        params: {source_urn: @source[:urn], note: "n"})
    assert_equal 404, status
    assert_empty conn[:resource_grants].to_a, "no mutation behind the 404"
  ensure
    conn[:workspaces].where(id: other_ws).delete if other_ws
    conn[:users].where(id: other).delete
  end

  def test_unowned_source_is_422_teaching_owner_only_never_a_fk_500
    sign_in_as_owner
    other = conn[:users].insert(handle: "gh-other-#{SecureRandom.hex(4)}",
                                github_uid: SecureRandom.uuid,
                                username: "u#{SecureRandom.hex(6)}",
                                name: "Other", created_at: Time.now)
    other_quest = OrchestratorFixtures.mint_quest(conn, user_id: other)
    other_source = OrchestratorFixtures.mint_source(conn, user_id: other,
                                                    quest_id: other_quest,
                                                    snapshot: "not yours")
    status, _, body = post("/workspaces/#{@workspace_id}/grants",
                           params: {source_urn: other_source[:urn], note: "n"})
    assert_equal 422, status
    assert_match "no source with urn", Array(body).join
    assert_match "owner-only", Array(body).join,
                 "fk_resource_grants_source (the X38 class) taught, never a 500"
    assert_empty conn[:resource_grants].to_a
  ensure
    conn[:quest_sources].where(source_id: other_source[:id]).delete if other_source
    conn[:sources].where(id: other_source[:id]).delete if other_source
    conn[:quests].where(id: other_quest).delete if other_quest
    conn[:users].where(id: other).delete
  end

  def test_blank_note_is_422_teaching_the_required_note_law
    sign_in_as_owner
    status, _, body = post("/workspaces/#{@workspace_id}/grants",
                           params: {source_urn: @source[:urn], note: "   "})
    assert_equal 422, status
    assert_match "a note is required", Array(body).join,
                 "the grant records who/why — never a silent visibility change"
    assert_empty conn[:resource_grants].to_a
  end

  def test_duplicate_grant_is_422_teaching_no_schema_unique_the_door_keeps_the_ledger_honest
    sign_in_as_owner
    post("/workspaces/#{@workspace_id}/grants",
         params: {source_urn: @source[:urn], note: "first"})
    status, _, body = post("/workspaces/#{@workspace_id}/grants",
                           params: {source_urn: @source[:urn], note: "second"})
    assert_equal 422, status
    assert_match "already granted", Array(body).join
    assert_equal 1, conn[:resource_grants].where(source_id: @source[:id]).count,
                 "duplicate grant rows are schema-legal — the DOOR refuses them"
  ensure
    conn[:resource_grants].delete
  end

  def test_creates_the_grant_row_with_the_full_audit_carriers
    sign_in_as_owner
    status, _, _ = post("/workspaces/#{@workspace_id}/grants",
                        params: {source_urn: @source[:urn], note: "the why"})
    assert_equal 302, status
    grant = conn[:resource_grants].where(source_id: @source[:id]).first
    refute_nil grant
    assert_equal @tenancy[:user_id], grant[:owner_user_id], "the who-carrier"
    assert_equal @workspace_id, grant[:grantee_workspace_id]
    assert_equal false, grant[:is_public]
    assert_equal "the why", grant[:note], "the why-carrier"
    refute_nil grant[:granted_at], "the when-carrier"
  ensure
    conn[:resource_grants].delete
  end
end
