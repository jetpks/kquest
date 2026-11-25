# frozen_string_literal: true

require_relative "action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /workspaces/:workspace_id/rename — rename workspace (I19 Spec Part
# 2): the owner gate selects by (id, created_by_user_id) — a non-owner or an
# absent workspace is 404 JSON BEFORE any mutation (existence never leaked);
# the teaching refusals ride 422.
class DashboardRenameWorkspaceTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @workspace_id = conn[:workspaces].insert(name: "ws-rename-01",
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

  def mint_other_workspace!
    @other_user_id = conn[:users].insert(handle: "gh-#{SecureRandom.hex(6)}",
                                         github_uid: SecureRandom.uuid,
                                         username: "u#{SecureRandom.hex(6)}",
                                         name: "Other", created_at: Time.now)
    conn[:workspaces].insert(name: "ws-other-own-01", created_by_user_id: @other_user_id)
  end

  def test_anonymous_is_redirected_to_sign_in_never_a_write
    status, headers, = post("/workspaces/#{@workspace_id}/rename", params: {name: "ws-x"})
    assert_equal 302, status
    assert_equal "/", headers["location"]
    assert_equal "ws-rename-01", conn[:workspaces].where(id: @workspace_id).get(:name)
  end

  def test_non_owner_or_absent_workspace_is_404_json_before_any_mutation
    sign_in_as_owner
    other = mint_other_workspace!

    status, headers, body = post("/workspaces/#{other}/rename", params: {name: "ws-hijack"})
    assert_equal 404, status, "a non-owner's workspace is indistinguishable from an absent one"
    assert_match "application/json", headers["content-type"]
    assert_equal JSON.parse(Array(body).join), {"error" => "Not found"}

    status, _, _ = post("/workspaces/#{SecureRandom.uuid}/rename", params: {name: "ws-x"})
    assert_equal 404, status

    assert_equal "ws-other-own-01", conn[:workspaces].where(id: other).get(:name),
                 "no mutation behind the 404"
    assert_equal "ws-rename-01", conn[:workspaces].where(id: @workspace_id).get(:name)
  ensure
    conn[:workspaces].where(id: other).delete if other
  end

  def test_renames_the_row_with_the_prg_redirect
    sign_in_as_owner
    status, _, _ = post("/workspaces/#{@workspace_id}/rename", params: {name: "ws-renamed-01"})
    assert_equal 302, status
    assert_equal "ws-renamed-01", conn[:workspaces].where(id: @workspace_id).get(:name)
  end

  def test_format_violation_is_422_teaching
    sign_in_as_owner
    status, _, body = post("/workspaces/#{@workspace_id}/rename", params: {name: "Bad Slug"})
    assert_equal 422, status
    assert_match "ck_workspaces_name", Array(body).join
    assert_equal "ws-rename-01", conn[:workspaces].where(id: @workspace_id).get(:name)
  end

  def test_taken_name_is_422_excluding_the_workspaces_own_id
    sign_in_as_owner
    status, _, _ = post("/workspaces/#{@workspace_id}/rename", params: {name: "ws-rename-01"})
    assert_equal 302, status, "renaming to its own name is NOT a refusal (uniqueness excludes self)"
    other = mint_other_workspace!
    status, _, body = post("/workspaces/#{@workspace_id}/rename",
                           params: {name: "ws-other-own-01"})
    assert_equal 422, status
    assert_match "already exists", Array(body).join
    assert_equal "ws-rename-01", conn[:workspaces].where(id: @workspace_id).get(:name)
  ensure
    conn[:workspaces].where(id: other).delete if other
  end
end
