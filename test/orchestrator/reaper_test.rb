# frozen_string_literal: true

require_relative "../test_helper"
require "async/redis"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/orchestrator/worker_registry"
require_relative "../../lib/kquest/orchestrator/reaper"
require_relative "../../lib/kquest/engine/session_supervisor"

# The reaper sweep (I04 DR-05, FM-21): open sessions whose session id no live
# worker claims get ended_at stamped — re-hosted against the REGISTRY
# liveness source; after reaping the gate is open (the cold-boot restart
# path, L7). The dead-holder-is-not-a-violation half lives here too: a dead
# worker's open session is the REAPER's transition, never the gate's.
class ReaperTest < Minitest::Test
  def setup
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    @quest_id = @tenancy[:quest_id]
    @phase_id = conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "decompose")
  end

  def teardown
    Kquest::Engine::SessionSupervisor.registry_clear
    OrchestratorFixtures.cleanup(conn, user_id: @user_id)
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def liveness = @liveness ||= Kquest::Engine::SessionSupervisor::InProcessLiveness.new

  def reaper = Kquest::Orchestrator::Reaper.new(conn: conn, liveness: liveness)

  def open_session(driver: "orchestrator")
    conn[:sessions].insert(user_id: @user_id, quest_id: @quest_id, phase_id: @phase_id,
                           mode: "autonomous", driver: driver, model: "test-model")
  end

  def test_open_session_claimed_by_a_live_worker_is_not_reaped
    session_id = open_session
    liveness.claim_session!(session_id)

    assert_empty reaper.sweep, "a live-held session survives the sweep"
    assert_nil conn[:sessions].where(id: session_id).get(:ended_at)
  end

  def test_orphaned_session_gets_ended_at_stamped
    session_id = open_session
    reaped = reaper.sweep

    assert_includes reaped, session_id
    refute_nil conn[:sessions].where(id: session_id).get(:ended_at),
               "the orphaned row is stamped (FM-21, the ledgered sweep)"
  end

  def test_after_reaping_the_gate_reopens
    supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn, liveness: liveness)
    session_id = open_session
    reaper.sweep

    new_session = supervisor.launch(user_id: @user_id, quest_id: @quest_id,
                                    phase_id: @phase_id, mode: "autonomous",
                                    driver: "orchestrator", model: "test-model")
    refute_nil new_session, "the reaped holder no longer blocks the gate (L7 cold-boot path)"
    refute_equal session_id, new_session
  end

  def test_sweep_scopes_to_the_quest_when_asked
    other = OrchestratorFixtures.mint_tenancy(conn)
    other_phase = conn[:phases].insert(user_id: other[:user_id], quest_id: other[:quest_id],
                                       kind: "decompose")
    other_session = conn[:sessions].insert(
      user_id: other[:user_id], quest_id: other[:quest_id], phase_id: other_phase,
      mode: "autonomous", driver: "orchestrator", model: "test-model"
    )
    mine = open_session

    reaped = reaper.sweep(quest_id: @quest_id)
    assert_includes reaped, mine
    assert_nil conn[:sessions].where(id: other_session).get(:ended_at),
               "another quest's orphans are not this sweep's"
    conn[:sessions].where(id: other_session).delete
    conn[:phases].where(id: other_phase).delete
    conn[:quests].where(id: other[:quest_id]).delete
    conn[:users].where(id: other[:user_id]).delete
  end
end
