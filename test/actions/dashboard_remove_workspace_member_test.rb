# frozen_string_literal: true

require_relative "action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /workspaces/:workspace_id/members/remove — remove member (I19 Spec
# Part 2): the owner gate first (404 non-leak), then the door deletes the
# membership row; not-a-member is the teaching refusal ("nothing to remove",
# the mute-remove shape).
class DashboardRemoveWorkspaceMemberTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @workspace_id = conn[:workspaces].insert(name: "ws-rmm-01",
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

  def mint_mate_with_membership!
    @other_user_id = conn[:users].insert(handle: "gh-mate-#{SecureRandom.hex(4)}",
                                         github_uid: SecureRandom.uuid,
                                         username: "u#{SecureRandom.hex(6)}",
                                         name: "Mate", created_at: Time.now)
    conn[:workspace_members].insert(workspace_id: @workspace_id, user_id: @other_user_id)
  end

  def mate_handle = conn[:users].where(id: @other_user_id).get(:handle)

  def test_anonymous_is_redirected_to_sign_in_never_a_write
    mint_mate_with_membership!
    status, headers, = post("/workspaces/#{@workspace_id}/members/remove",
                            params: {handle: mate_handle})
    assert_equal 302, status
    assert_equal "/", headers["location"]
    assert_equal 1, conn[:workspace_members].count, "no anonymous mutation"
  end

  def test_non_owner_or_absent_workspace_is_404_json_before_any_mutation
    mint_mate_with_membership!
    sign_in_as_owner
    other = conn[:users].insert(handle: "gh-other-#{SecureRandom.hex(4)}",
                                github_uid: SecureRandom.uuid,
                                username: "u#{SecureRandom.hex(6)}",
                                name: "Other", created_at: Time.now)
    other_ws = conn[:workspaces].insert(name: "ws-rmm-other", created_by_user_id: other)

    status, headers, body = post("/workspaces/#{other_ws}/members/remove",
                                 params: {handle: mate_handle})
    assert_equal 404, status
    assert_match "application/json", headers["content-type"]
    assert_equal JSON.parse(Array(body).join), {"error" => "Not found"}
    status, _, _ = post("/workspaces/#{SecureRandom.uuid}/members/remove",
                        params: {handle: mate_handle})
    assert_equal 404, status
    assert_equal 1, conn[:workspace_members].count, "no mutation behind the 404"
  ensure
    conn[:workspaces].where(id: other_ws).delete if other_ws
    conn[:users].where(id: other).delete
  end

  def test_removes_the_membership_row
    mint_mate_with_membership!
    sign_in_as_owner
    status, _, _ = post("/workspaces/#{@workspace_id}/members/remove",
                        params: {handle: mate_handle})
    assert_equal 302, status
    assert_empty conn[:workspace_members].where(workspace_id: @workspace_id,
                                                user_id: @other_user_id)
  end

  def test_not_a_member_is_422_teaching_nothing_to_remove
    sign_in_as_owner
    status, _, body = post("/workspaces/#{@workspace_id}/members/remove",
                           params: {handle: "gh-never-a-member"})
    assert_equal 422, status
    assert_match "not a member", Array(body).join
    assert_match "nothing to remove", Array(body).join, "the mute-remove shape"
  end
end
