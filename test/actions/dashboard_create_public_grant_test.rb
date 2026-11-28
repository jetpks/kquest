# frozen_string_literal: true

require_relative "action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /grants/public — grant public (I19 Spec Part 2): the operator's OWN
# source by (urn, user_id) — the X38 class taught — REQUIRED note, an
# existing public grant taught. The insert carries is_public: true with BOTH
# grantee columns NULL (the exactly-one shape is the door's own).
class DashboardCreatePublicGrantTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @source = OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                               quest_id: @tenancy[:quest_id],
                                               snapshot: "public grant action test text")
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
    status, headers, = post("/grants/public",
                            params: {source_urn: @source[:urn], note: "n"})
    assert_equal 302, status
    assert_equal "/", headers["location"]
    assert_empty conn[:resource_grants].to_a
  end

  def test_unowned_source_is_422_teaching_owner_only
    sign_in_as_owner
    other = conn[:users].insert(handle: "gh-other-#{SecureRandom.hex(4)}",
                                github_uid: SecureRandom.uuid,
                                username: "u#{SecureRandom.hex(6)}",
                                name: "Other", created_at: Time.now)
    other_quest = OrchestratorFixtures.mint_quest(conn, user_id: other)
    other_source = OrchestratorFixtures.mint_source(conn, user_id: other,
                                                    quest_id: other_quest,
                                                    snapshot: "not yours")
    status, _, body = post("/grants/public",
                           params: {source_urn: other_source[:urn], note: "n"})
    assert_equal 422, status
    assert_match "owner-only", Array(body).join
    assert_empty conn[:resource_grants].to_a
  ensure
    conn[:quest_sources].where(source_id: other_source[:id]).delete if other_source
    conn[:sources].where(id: other_source[:id]).delete if other_source
    conn[:quests].where(id: other_quest).delete if other_quest
    conn[:users].where(id: other).delete
  end

  def test_blank_note_is_422_teaching_the_required_note_law
    sign_in_as_owner
    status, _, body = post("/grants/public", params: {source_urn: @source[:urn], note: ""})
    assert_equal 422, status
    assert_match "a note is required", Array(body).join
    assert_empty conn[:resource_grants].to_a
  end

  def test_duplicate_public_grant_is_422_teaching
    sign_in_as_owner
    post("/grants/public", params: {source_urn: @source[:urn], note: "first"})
    status, _, body = post("/grants/public",
                           params: {source_urn: @source[:urn], note: "second"})
    assert_equal 422, status
    assert_match "already has a public grant", Array(body).join
    assert_equal 1, conn[:resource_grants].where(source_id: @source[:id]).count
  ensure
    conn[:resource_grants].delete
  end

  def test_creates_the_public_grant_row
    sign_in_as_owner
    status, _, _ = post("/grants/public",
                        params: {source_urn: @source[:urn], note: "the public why"})
    assert_equal 302, status
    grant = conn[:resource_grants].where(source_id: @source[:id]).first
    refute_nil grant
    assert_equal @tenancy[:user_id], grant[:owner_user_id]
    assert_equal true, grant[:is_public]
    assert_nil grant[:grantee_user_id], "the exactly-one shape is the door's own"
    assert_nil grant[:grantee_workspace_id]
    assert_equal "the public why", grant[:note]
  ensure
    conn[:resource_grants].delete
  end
end
