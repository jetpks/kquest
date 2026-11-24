# frozen_string_literal: true

require_relative "../test_helper"
require "async/redis"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/orchestrator/worker_registry"
require_relative "../../lib/kquest/orchestrator/reaper"
require_relative "../../lib/kquest/engine/session_supervisor"

# The launch gate goes LIVE (I04 DR-05; the recorded I13 seam): the gate
# transaction is unchanged — `FOR UPDATE` on the quests row FIRST, then the
# liveness check + insert — but the liveness source is now the PORT, backed
# by the redis worker registry. The I13 in-process behaviors are unchanged
# (their tests stay green); these tests pin the registry-backed shape:
# racing launches serialize (TOCTOU dead), the refusal names the holder
# session + driver, a dead worker's open session is NOT a violation (the
# reaper's), reaping re-opens the gate, and operator + orchestrator launches
# compete for the SAME gate (L13).
class LaunchGateTest < Minitest::Test
  def setup
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    @quest_id = @tenancy[:quest_id]
    @phase_id = conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "decompose")
    @prefix = OrchestratorFixtures.redis_prefix
    @redis = OrchestratorFixtures.redis_client
  end

  def teardown
    Sync { @workers.each(&:unregister!) } if @workers
    Sync { OrchestratorFixtures.cleanup_redis(@redis, @prefix) } if @redis
    @redis&.close
    Kquest::Engine::SessionSupervisor.registry_clear
    OrchestratorFixtures.cleanup(conn, user_id: @user_id)
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def workers = @workers ||= []

  def registry_for(worker_uuid: nil)
    Kquest::Orchestrator::WorkerRegistry.new(redis: @redis, kind: "quest", quest_id: @quest_id,
                                             prefix: @prefix).tap { |r| workers << r }
  end

  def supervisor(conn_ = conn)
    Kquest::Engine::SessionSupervisor.new(conn: conn_, liveness: registry_for)
  end

  def launch(sup, driver: "orchestrator")
    sup.launch(user_id: @user_id, quest_id: @quest_id, phase_id: @phase_id,
               mode: "autonomous", driver: driver, model: "engine-test-model")
  end

  def test_concurrent_second_writer_refused_under_for_update
    Sync do
      winner = nil
      refusals = []
      barrier = Async::Task.current
      t1 = barrier.async do
        winner = launch(supervisor(conn))
      rescue Kquest::Engine::Error => e
        refusals << e.message
      end
      conn2 = Sequel.connect(ENV.fetch("DATABASE_URL", "postgres:///kquest_test"))
      begin
        t2 = barrier.async do
          launch(supervisor(conn2))
        rescue Kquest::Engine::Error => e
          refusals << e.message
        end
        t2.wait
      ensure
        conn2.disconnect
      end
      t1.wait

      assert winner, "exactly one launch wins the row lock"
      sessions = conn[:sessions].where(quest_id: @quest_id).count
      assert_equal 1, sessions, "TOCTOU dead: the FOR UPDATE row lock serializes the racers"
      assert_equal 1, refusals.size, "the loser is refused"
    end
  end

  def test_refusal_names_holder_session_and_driver
    Sync do
      sup = supervisor(conn)
      holder = launch(sup, driver: "orchestrator")

      error = assert_raises(Kquest::Engine::Error) { launch(sup, driver: "operator") }
      assert_includes error.message, holder.to_s, "the refusal names the holder session"
      assert_includes error.message, "orchestrator", "the refusal names the holder driver"
      assert_includes error.message, "WRITE-GUARD", "the frozen write-guard shape"
    end
  end

  def test_dead_worker_session_is_not_a_violation
    Sync do
      sup = supervisor(conn)
      abandoned = launch(sup, driver: "orchestrator")
      # The worker DIES: its registry entry disappears with it (the TTL).
      workers.last.unregister!
      workers.pop

      fresh = launch(supervisor(conn))
      refute_nil fresh, "a dead holder is NOT a gate violation — the reaper owns that transition"
      refute_equal abandoned, fresh
    end
  end

  def test_reaper_reopens_the_gate
    Sync do
      sup = supervisor(conn)
      holder = launch(sup, driver: "orchestrator")
      workers.last.unregister! # the holder's worker is gone

      reaper = Kquest::Orchestrator::Reaper.new(
        conn: conn,
        liveness: Kquest::Orchestrator::WorkerRegistry.new(redis: @redis, kind: "reaper",
                                                           prefix: @prefix)
      )
      assert_includes reaper.sweep(quest_id: @quest_id), holder

      fresh = launch(supervisor(conn))
      refute_nil fresh, "after reaping, the gate re-opens (the cold-boot restart path)"
    end
  end

  def test_operator_and_orchestrator_launches_compete_for_the_same_gate
    Sync do
      sup = supervisor(conn)
      operator_session = launch(sup, driver: "operator")

      error = assert_raises(Kquest::Engine::Error) { launch(sup, driver: "orchestrator") }
      assert_includes error.message, operator_session.to_s
      assert_includes error.message, "operator",
                     "L13: one active writer per quest holds for BOTH launch modes"

      # And the reverse: the orchestrator holding excludes the operator.
      sup.bank_session!(session_id: operator_session)
      orchestrator_session = launch(sup, driver: "orchestrator")
      error2 = assert_raises(Kquest::Engine::Error) { launch(sup, driver: "operator") }
      assert_includes error2.message, orchestrator_session.to_s
    end
  end
end
