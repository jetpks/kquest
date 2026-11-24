# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /quests/:quest_id/pause — the lifecycle door's PAUSE half (I16 Part 1 /
# D5): the ledgered active → paused transition; refusals are 422 with NO
# ledger row and NO state change; the visibility gate on both sides; no
# spawn (the launcher owns worker boot).
class QuestPauseTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
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

  def post_pause(quest_id) = post("/quests/#{quest_id}/pause")

  def test_active_quest_pauses_with_a_ledgered_transition
    status, headers, = post_pause(@tenancy[:quest_id])
    assert_equal 302, status
    assert_equal "paused", conn[:quests].where(id: @tenancy[:quest_id]).first[:state]
    row = conn[:quest_lifecycle_events].where(quest_id: @tenancy[:quest_id]).first
    refute_nil row, "quests.state + the lifecycle ledger are the ONLY mutations"
    assert_equal "active", row[:from_state]
    assert_equal "paused", row[:to_state]
    assert_equal "operator", row[:actor]
    assert_includes row[:note], "ui pause door"
    assert_match %r{/quests/#{@tenancy[:quest_id]}}, headers["location"]
    # no phase/session/tool_call mutation (AC4/AC5)
    assert_empty conn[:phases].where(quest_id: @tenancy[:quest_id])
    assert_empty conn[:sessions].where(quest_id: @tenancy[:quest_id])
  end

  def test_non_active_quest_is_422_with_no_ledger_row_and_no_state_change
    conn[:quests].where(id: @tenancy[:quest_id]).update(state: "paused")
    before = conn[:quest_lifecycle_events].count
    status, _, body = post_pause(@tenancy[:quest_id])
    assert_equal 422, status
    assert_match "not active", Array(body).join
    assert_equal before, conn[:quest_lifecycle_events].count, "NO ledger row on refusal"
    assert_equal "paused", conn[:quests].where(id: @tenancy[:quest_id]).first[:state],
                 "NO state change on refusal"
  end

  def test_invisible_quest_is_404_before_any_mutation
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    before = conn[:quest_lifecycle_events].count
    status, = post_pause(other[:quest_id])
    assert_equal 404, status
    assert_equal before, conn[:quest_lifecycle_events].count
    assert_equal "active", conn[:quests].where(id: other[:quest_id]).first[:state]
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_absent_quest_is_404
    status, = post_pause(SecureRandom.uuid)
    assert_equal 404, status
  end

  def test_anonymous_redirects_to_sign_in_without_a_transition
    sign_out
    before = conn[:quest_lifecycle_events].count
    status, headers, = post_pause(@tenancy[:quest_id])
    assert_equal 302, status
    assert_equal "/", headers["location"]
    assert_equal before, conn[:quest_lifecycle_events].count
  end

  def test_no_process_is_ever_spawned
    Process.stub(:spawn, ->(*_args) { flunk "the UI never spawns — the launcher owns worker boot" }) do
      post_pause(@tenancy[:quest_id])
    end
  end
end
