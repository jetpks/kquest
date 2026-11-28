# frozen_string_literal: true

require_relative "action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /workspaces/:workspace_id/members — add member (I19 Spec Part 2): the
# owner gate first (404 non-leak), then the door adds by users.handle —
# unknown handle / duplicate membership taught 422 (pk_workspace_members is
# the backstop). joined_at is the membership write's when-carrier.
class DashboardAddWorkspaceMemberTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @workspace_id = conn[:workspaces].insert(name: "ws-members-01",
                                             created_by_user_id: @tenancy[:user_id])
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

  def mint_mate!
    @other_user_id = conn[:users].insert(handle: "gh-mate-#{SecureRandom.hex(4)}",
                                         github_uid: SecureRandom.uuid,
                                         username: "u#{SecureRandom.hex(6)}",
                                         name: "Mate", created_at: Time.now)
  end

  def mate_handle = conn[:users].where(id: @other_user_id).get(:handle)

  def test_anonymous_is_redirected_to_sign_in_never_a_write
    status, headers, = post("/workspaces/#{@workspace_id}/members",
                            params: {handle: "gh-someone"})
    assert_equal 302, status
    assert_equal "/", headers["location"]
    assert_empty conn[:workspace_members].to_a
  end

  def test_non_owner_or_absent_workspace_is_404_json_before_any_mutation
    sign_in_as_owner
    other = conn[:users].insert(handle: "gh-other-#{SecureRandom.hex(4)}",
                                github_uid: SecureRandom.uuid,
                                username: "u#{SecureRandom.hex(6)}",
                                name: "Other", created_at: Time.now)
    other_ws = conn[:workspaces].insert(name: "ws-members-other",
                                        created_by_user_id: other)

    status, headers, body = post("/workspaces/#{other_ws}/members",
                                 params: {handle: "gh-anyone"})
    assert_equal 404, status
    assert_match "application/json", headers["content-type"]
    assert_equal JSON.parse(Array(body).join), {"error" => "Not found"}
    status, _, _ = post("/workspaces/#{SecureRandom.uuid}/members",
                        params: {handle: "gh-anyone"})
    assert_equal 404, status
    assert_empty conn[:workspace_members].to_a, "no mutation behind the 404"
  ensure
    conn[:workspaces].where(id: other_ws).delete if other_ws
    conn[:users].where(id: other).delete
  end

  def test_adds_the_member_row_with_joined_at
    sign_in_as_owner
    mint_mate!
    status, _, _ = post("/workspaces/#{@workspace_id}/members", params: {handle: mate_handle})
    assert_equal 302, status
    row = conn[:workspace_members].where(workspace_id: @workspace_id,
                                         user_id: @other_user_id).first
    refute_nil row
    refute_nil row[:joined_at], "the membership write's when-carrier"
  end

  def test_unknown_handle_is_422_teaching
    sign_in_as_owner
    status, _, body = post("/workspaces/#{@workspace_id}/members",
                           params: {handle: "gh-never-minted"})
    assert_equal 422, status
    assert_match "no user with handle", Array(body).join
    assert_empty conn[:workspace_members].to_a
  end

  def test_duplicate_membership_is_422_teaching_pk_workspace_members
    sign_in_as_owner
    mint_mate!
    post("/workspaces/#{@workspace_id}/members", params: {handle: mate_handle})
    status, _, body = post("/workspaces/#{@workspace_id}/members",
                           params: {handle: mate_handle})
    assert_equal 422, status
    assert_match "already a member", Array(body).join,
                 "X40's refusal taught BEFORE the insert"
    assert_equal 1, conn[:workspace_members].where(workspace_id: @workspace_id).count
  end
end
