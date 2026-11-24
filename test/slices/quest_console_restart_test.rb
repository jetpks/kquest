# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# POST /quests/:quest_id/console/restart — the steering door's RESTART half
# (I17 Part 2 / AC5): `stopped → active` (the graph_invalid repair
# precedent) carrying the SAME recorded-merge params as the steering resume
# (only-raise budgets + shallow config merges + required note on change);
# ONE for_update transaction, ONE ledger row; a live operator session
# refuses 422 naming the holder; no spawn.
class QuestConsoleRestartTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    Kquest::Engine::SessionSupervisor.registry_clear
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn, state: "stopped", web_call_budget: 16)
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

  def post_restart(params) = post("/quests/#{@tenancy[:quest_id]}/console/restart", params: params)

  def test_restart_is_the_ledgered_stopped_to_active_pair_with_the_recorded_merges
    status, = post_restart(web_call_budget: 64,
                           process_config: '{"modes":{"token_budget":"hard"}}',
                           note: "repaired the graph — resuming with the routing hard-mode")
    assert_equal 302, status
    quest = conn[:quests].where(id: @tenancy[:quest_id]).first
    assert_equal "active", quest[:state]
    assert_equal 64, quest[:web_call_budget]
    process_config = JSON.parse(quest[:process_config].is_a?(String) ? quest[:process_config] : quest[:process_config].to_json)
    assert_equal "hard", process_config.dig("modes", "token_budget")
    row = conn[:quest_lifecycle_events].where(quest_id: @tenancy[:quest_id]).first
    assert_equal "stopped", row[:from_state]
    assert_equal "active", row[:to_state]
    assert_equal "operator", row[:actor]
    assert_includes row[:note], "ui console restart door"
    assert_includes row[:note], "web_call_budget 16→64"
    assert_includes row[:note], "why: repaired the graph"
  end

  def test_the_only_raise_law_bites_on_restart_too
    before = conn[:quest_lifecycle_events].count
    status, _, body = post_restart(web_call_budget: 8, note: "why")
    assert_equal 422, status
    assert_match(/a cap may only RAISE on resume \(I06 §6\.2\)/, Array(body).join)
    assert_equal before, conn[:quest_lifecycle_events].count
    assert_equal "stopped", conn[:quests].where(id: @tenancy[:quest_id]).first[:state]
  end

  def test_a_non_stopped_quest_refuses_422_with_no_row
    conn[:quests].where(id: @tenancy[:quest_id]).update(state: "paused")
    before = conn[:quest_lifecycle_events].count
    status, _, body = post_restart({})
    assert_equal 422, status
    assert_match(/restart door is the ledgered stopped → active pair/, Array(body).join)
    assert_equal before, conn[:quest_lifecycle_events].count
    assert_equal "paused", conn[:quests].where(id: @tenancy[:quest_id]).first[:state]
  end

  def test_a_live_operator_session_holding_the_quest_refuses_naming_the_holder
    quest = conn[:quests].where(id: @tenancy[:quest_id]).first
    conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id], kind: "decompose")
    session = Kquest::Ui::OperatorWrite.open_session!(
      conn, user: {id: @tenancy[:user_id], username: "the-operator"}, quest: quest
    )
    before = conn[:quest_lifecycle_events].count
    status, _, body = post_restart({})
    assert_equal 422, status
    joined = Array(body).join
    assert_includes joined, "WRITE-GUARD"
    assert_includes joined, session.fetch(:id).to_s
    assert_equal before, conn[:quest_lifecycle_events].count
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, state: "stopped", topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/console/restart", params: {})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_no_process_is_ever_spawned
    Process.stub(:spawn, ->(*_args) { flunk "the UI never spawns — the launcher owns worker boot" }) do
      post_restart({note: "why"})
    end
  end
end
