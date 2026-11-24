# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /quests/:quest_id/console/session/end — the operator attach end and
# the briefing's SIGN-OFF (I17 Part 2 / Part 3, DR-04 ruling A): the open
# operator session's ended_at is stamped (the session's own audit is the
# record — no lifecycle row); 422 with the teaching refusal when no open
# operator session exists.
class QuestConsoleSessionEndTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    Kquest::Engine::SessionSupervisor.registry_clear
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn, state: "paused")
    sign_in_as_owner
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    Kquest::Engine::SessionSupervisor.registry_clear
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  Owner = Struct.new(:id, :github_uid, :username, :name, :email, :avatar_url, keyword_init: true)

  def sign_in_as_owner
    row = conn[:users].where(id: @tenancy[:user_id]).first
    sign_in(Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                      name: row[:name], email: row[:email], avatar_url: row[:avatar_url]))
  end

  def test_the_sign_off_stamps_ended_at_with_no_lifecycle_row
    quest = conn[:quests].where(id: @tenancy[:quest_id]).first
    session_id = Kquest::Ui::OperatorWrite.open_session!(
      conn, user: {id: @tenancy[:user_id], username: "op"}, quest: quest
    ).fetch(:id)
    status, = post("/quests/#{@tenancy[:quest_id]}/console/session/end", params: {})
    assert_equal 302, status
    row = conn[:sessions].where(id: session_id).first
    refute_nil row[:ended_at], "the DR-04 sign-off stamps ended_at"
    assert_empty conn[:quest_lifecycle_events],
                 "no transition occurred — the session's own audit is the record"
  end

  def test_no_open_operator_session_refuses_422_teaching
    status, _, body = post("/quests/#{@tenancy[:quest_id]}/console/session/end", params: {})
    assert_equal 422, status
    assert_match(/no open operator session/, Array(body).join)
  end

  def test_an_orchestrator_session_is_not_the_operators_sign_off_target
    phase_id = conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    kind: "decompose")
    conn[:sessions].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                           phase_id: phase_id, mode: "autonomous", driver: "orchestrator",
                           model: "test-model")
    status, _, body = post("/quests/#{@tenancy[:quest_id]}/console/session/end", params: {})
    assert_equal 422, status, "the sign-off ends the OPERATOR's session only"
    assert_match(/no open operator session/, Array(body).join)
    assert_nil conn[:sessions].where(driver: "orchestrator").first[:ended_at],
               "the orchestrator's session is untouched"
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, state: "paused", topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/console/session/end", params: {})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end
end
