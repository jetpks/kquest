# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /quests/:quest_id/console/stop — the steering door's STOP half (I17
# Part 2 / AC5): `paused → stopped` ONLY, ONE for_update transaction, ONE
# ledger row; 422 on any other state with NO row and NO state change; no
# spawn.
class QuestConsoleStopTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn, state: "paused")
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
    sign_in(Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                      name: row[:name], email: row[:email], avatar_url: row[:avatar_url]))
  end

  def test_stop_is_the_ledgered_paused_to_stopped_pair
    status, = post("/quests/#{@tenancy[:quest_id]}/console/stop",
                   params: {note: "abandon cleanly — the briefing caps disposition"})
    assert_equal 302, status
    assert_equal "stopped", conn[:quests].where(id: @tenancy[:quest_id]).first[:state]
    row = conn[:quest_lifecycle_events].where(quest_id: @tenancy[:quest_id]).first
    refute_nil row
    assert_equal "paused", row[:from_state]
    assert_equal "stopped", row[:to_state]
    assert_equal "operator", row[:actor]
    assert_includes row[:note], "ui console stop door"
    assert_includes row[:note], "why: abandon cleanly"
    # no phase/session/tool_calls writes (the ledgered transition is the whole action)
    assert_empty conn[:phases].where(quest_id: @tenancy[:quest_id])
    assert_empty conn[:sessions].where(quest_id: @tenancy[:quest_id])
  end

  def test_a_non_paused_quest_refuses_422_with_no_row
    conn[:quests].where(id: @tenancy[:quest_id]).update(state: "active")
    before = conn[:quest_lifecycle_events].count
    status, _, body = post("/quests/#{@tenancy[:quest_id]}/console/stop", params: {})
    assert_equal 422, status
    assert_match(/stop door is the ledgered paused → stopped pair/, Array(body).join)
    assert_equal before, conn[:quest_lifecycle_events].count, "NO ledger row"
    assert_equal "active", conn[:quests].where(id: @tenancy[:quest_id]).first[:state],
                 "NO state change"
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, state: "paused", topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/console/stop", params: {})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = post("/quests/#{@tenancy[:quest_id]}/console/stop", params: {})
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_no_process_is_ever_spawned
    Process.stub(:spawn, ->(*_args) { flunk "the UI never spawns — the launcher owns worker boot" }) do
      post("/quests/#{@tenancy[:quest_id]}/console/stop", params: {})
    end
  end
end
