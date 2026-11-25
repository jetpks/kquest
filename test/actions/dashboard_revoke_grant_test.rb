# frozen_string_literal: true

require_relative "action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /grants/:grant_id/revoke — revoke (I19 Spec Part 2): the grant row
# selected by (id, owner_user_id) — ANY scope is revocable, the row is the
# operator's own; a non-owner gets 404 JSON BEFORE any mutation. The door
# deletes the row — revocation IS row deletion, private = absence (the I02
# law).
class DashboardRevokeGrantTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @source = OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                               quest_id: @tenancy[:quest_id],
                                               snapshot: "revoke action test text")
    @grant_id = conn[:resource_grants].insert(owner_user_id: @tenancy[:user_id],
                                              source_id: @source[:id], is_public: true,
                                              note: "the why")
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
    status, headers, = post("/grants/#{@grant_id}/revoke")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    refute_nil conn[:resource_grants].where(id: @grant_id).first
  end

  def test_non_owner_or_absent_grant_is_404_json_before_any_mutation
    sign_in_as_owner
    @other_user_id = conn[:users].insert(handle: "gh-other-#{SecureRandom.hex(4)}",
                                         github_uid: SecureRandom.uuid,
                                         username: "u#{SecureRandom.hex(6)}",
                                         name: "Other", created_at: Time.now)
    other_quest = OrchestratorFixtures.mint_quest(conn, user_id: @other_user_id)
    other_source = OrchestratorFixtures.mint_source(conn, user_id: @other_user_id,
                                                    quest_id: other_quest,
                                                    snapshot: "not yours")
    other_grant = conn[:resource_grants].insert(owner_user_id: @other_user_id,
                                                source_id: other_source[:id],
                                                is_public: true, note: "theirs")

    status, headers, body = post("/grants/#{other_grant}/revoke")
    assert_equal 404, status, "a non-owner's grant is indistinguishable from an absent one"
    assert_match "application/json", headers["content-type"]
    assert_equal JSON.parse(Array(body).join), {"error" => "Not found"}
    status, _, _ = post("/grants/#{SecureRandom.uuid}/revoke")
    assert_equal 404, status
    refute_nil conn[:resource_grants].where(id: other_grant).first, "no mutation behind the 404"
    refute_nil conn[:resource_grants].where(id: @grant_id).first
  ensure
    conn[:resource_grants].where(id: other_grant).delete if other_grant
    conn[:quest_sources].where(source_id: other_source[:id]).delete if other_source
    conn[:sources].where(id: other_source[:id]).delete if other_source
    conn[:quests].where(id: other_quest).delete if other_quest
  end

  def test_revocation_is_row_deletion_private_is_absence
    sign_in_as_owner
    status, _, _ = post("/grants/#{@grant_id}/revoke")
    assert_equal 302, status
    assert_empty conn[:resource_grants].where(id: @grant_id),
                 "revocation IS row deletion — the I02 absence law"
  end
end
