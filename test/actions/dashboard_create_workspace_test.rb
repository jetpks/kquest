# frozen_string_literal: true

require_relative "action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /workspaces — create workspace (I19 Spec Part 2): the owner-less
# create lands the workspaces row AND the creator's membership row in ONE
# transaction (the audit ruling — the rows ARE the record). Teaching
# refusals (blank / ck_workspaces_name / uq_workspaces_name) are 422, never
# a CHECK 500; no partial rows behind a refusal.
class DashboardCreateWorkspaceTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    conn[:resource_grants].delete
    conn[:workspace_members].delete
    conn[:workspaces].delete
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  Owner = Struct.new(:id, :github_uid, :username, :name, :email, :avatar_url, keyword_init: true)

  def sign_in_as_owner
    row = conn[:users].where(id: @tenancy[:user_id]).first
    sign_in(Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                      name: row[:name], email: row[:email], avatar_url: row[:avatar_url]))
  end

  def test_anonymous_is_redirected_to_sign_in_never_a_write
    status, headers, = post("/workspaces", params: {name: "ws-anon"})
    assert_equal 302, status
    assert_equal "/", headers["location"]
    assert_empty conn[:workspaces].to_a
  end

  def test_creates_the_workspace_and_the_creator_membership_pair
    sign_in_as_owner
    status, headers, = post("/workspaces", params: {name: "ws-created-01"})
    assert_equal 302, status
    workspace = conn[:workspaces].where(name: "ws-created-01").first
    refute_nil workspace
    assert_equal @tenancy[:user_id], workspace[:created_by_user_id]
    membership = conn[:workspace_members].where(workspace_id: workspace[:id]).first
    refute_nil membership, "the creator IS a member (the frozen I02 fixture shape)"
    assert_equal @tenancy[:user_id], membership[:user_id]
    refute_nil membership[:joined_at]
    assert_match %r{/$}, headers["location"], "the PRG redirect back (fallback /)"
  ensure
    conn[:workspace_members].where(workspace_id: workspace[:id]).delete if workspace
    conn[:workspaces].where(id: workspace[:id]).delete if workspace
  end

  def test_blank_name_is_422_teaching_with_no_row
    sign_in_as_owner
    status, _, body = post("/workspaces", params: {name: "   "})
    assert_equal 422, status
    assert_match "name is required", Array(body).join
    assert_empty conn[:workspaces].to_a
  end

  def test_format_violation_is_422_teaching_ck_workspaces_name_never_a_check_500
    sign_in_as_owner
    ["NOT-A-SLUG", "UPPER", "-lead", "spaced name"].each do |bad|
      status, _, body = post("/workspaces", params: {name: bad})
      assert_equal 422, status, "bad name #{bad.inspect} teaches"
      assert_match "name must match", Array(body).join
      assert_match "ck_workspaces_name", Array(body).join,
                   "the CHECK is taught, never the user-facing error"
    end
    assert_empty conn[:workspaces].to_a
  end

  def test_taken_name_is_422_teaching_uq_workspaces_name_is_global
    sign_in_as_owner
    post("/workspaces", params: {name: "ws-taken-01"})
    status, _, body = post("/workspaces", params: {name: "ws-taken-01"})
    assert_equal 422, status
    assert_match "already exists", Array(body).join,
                 "uq_workspaces_name is GLOBAL — taught, never a 500"
    assert_equal 1, conn[:workspaces].where(name: "ws-taken-01").count, "no second row"
    assert_equal 1, conn[:workspace_members].count, "no partial rows behind the refusal"
  ensure
    conn[:workspace_members].delete
    conn[:workspaces].delete
  end
end
