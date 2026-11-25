# frozen_string_literal: true

require_relative "../test_helper"
require "async/redis"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/orchestrator/quest_worker"
require_relative "../../lib/kquest/orchestrator/phase_runner"
require_relative "../../lib/kquest/orchestrator/worker_registry"
require_relative "../../lib/kquest/engine/session_supervisor"

# The quest worker process (I08 §2.1, DR-02 ruling A): boots ONE worker for
# ONE active quest, registers in the worker registry, exits when the quest
# leaves `active` (exit is safe: nothing is live; resume is a fresh worker,
# L7). Keyless: the phase machinery underneath is exercised by the runner's
# own tests and the scripted quest; these pins are the worker's OWN law.
class QuestWorkerTest < Minitest::Test
  def setup
    @prefix = OrchestratorFixtures.redis_prefix
    @redis = OrchestratorFixtures.redis_client
  end

  def teardown
    Sync { @registry&.unregister! }
    Sync { OrchestratorFixtures.cleanup_redis(@redis, @prefix) } if @redis
    @redis&.close
    OrchestratorFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def mint_quest(state:, process_config: {})
    t = OrchestratorFixtures.mint_tenancy(conn, state: state, process_config: process_config)
    @user_id = t[:user_id]
    t[:quest_id]
  end

  def registry(quest_id)
    @registry ||= Kquest::Orchestrator::WorkerRegistry.new(redis: @redis, kind: "quest",
                                                           quest_id: quest_id, prefix: @prefix)
  end

  def worker(quest_id)
    r = registry(quest_id)
    supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn, liveness: r)
    runner = Kquest::Orchestrator::PhaseRunner.new(conn: conn, supervisor: supervisor)
    Kquest::Orchestrator::QuestWorker.new(conn: conn, quest_id: quest_id, registry: r,
                                          supervisor: supervisor, runner: runner,
                                          sleeper: ->(_s) {})
  end

  def test_boots_only_on_active_and_never_registers_for_a_paused_quest
    quest_id = mint_quest(state: "paused")
    Sync do
      assert_equal :not_active, worker(quest_id).run
      assert_empty Kquest::Orchestrator::WorkerRegistry.live_workers(@redis, prefix: @prefix),
                   "a paused quest gets no worker and no registry entry"
    end
  end

  def test_boots_on_active_registers_and_reaps_then_exits_when_no_briefing_landed
    quest_id = mint_quest(state: "active")
    Sync do
      assert_equal :awaiting_briefing, worker(quest_id).run,
                   "no phases row + no staged agenda = the briefing has not landed"
      assert_empty Kquest::Orchestrator::WorkerRegistry.live_workers(@redis, prefix: @prefix),
                   "the exit unregisters (the TTL would also expire it)"
      # The boot reaper pass ran (a sweep is a no-op on a clean quest).
      assert_empty conn[:quest_lifecycle_events].where(quest_id: quest_id).to_a
    end
  end

  def test_exits_when_the_quest_leaves_active_mid_run
    # The runner's loud fallback: an unmatchable boundary pauses the quest —
    # the worker's loop then exits BECAUSE the quest left `active`.
    quest_id = mint_quest(state: "active")
    phase_id = conn[:phases].insert(user_id: @user_id, quest_id: quest_id,
                                    kind: "decompose", state: "complete",
                                    started_at: Time.now, ended_at: Time.now)
    Sync do
      verdict = worker(quest_id).run
      assert_equal :paused, verdict
      assert_equal "paused", conn[:quests].where(id: quest_id).get(:state),
                   "the quest left active — the worker exits (L7: resume is a fresh worker)"
      lifecycle = conn[:quest_lifecycle_events].where(quest_id: quest_id).order(Sequel.desc(:occurred_at)).first
      assert_equal "paused", lifecycle[:to_state]
    ensure
      conn[:phases].where(id: phase_id).delete if phase_id
    end
  end

  # ── the §8 amendment's loop law (AC7): the briefing verdicts LOOP ──────

  # A stub runner carrying a scripted verdict sequence + a probe for the
  # after_turn wiring (the worker wires `-> { periodic_passes }` at boot).
  class ScriptedRunner
    attr_reader :after_turn_set
    attr_accessor :verdicts

    def initialize(verdicts)
      @verdicts = verdicts
      @after_turn_set = nil
    end

    def after_turn=(callable)
      @after_turn_set = callable
    end

    def run_next(_quest_id)
      v = @verdicts.shift
      raise Minitest::Assertion, "the scripted verdicts ran dry (a LOOP ran away)" if v.nil?

      v
    end
  end

  def scripted_worker(quest_id, runner)
    r = registry(quest_id)
    supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn, liveness: r)
    Kquest::Orchestrator::QuestWorker.new(conn: conn, quest_id: quest_id, registry: r,
                                          supervisor: supervisor, runner: runner,
                                          watcher: nil, projector: nil,
                                          sleeper: ->(_s) {})
  end

  def test_worker_loops_on_briefing_hold_and_briefing_ran_and_wires_after_turn
    quest_id = mint_quest(state: "active")
    runner = ScriptedRunner.new(%i[briefing_hold briefing_ran briefing_hold no_work])
    passes = 0

    Sync do
      worker = scripted_worker(quest_id, runner)
      # periodic_passes probe: the projector seam (the loop's own pass list:
      # reaper sweep + projector pass + watcher census).
      projector = Object.new
      projector.define_singleton_method(:project) { |_qid| passes += 1 }
      worker.instance_variable_set(:@projector, projector)

      verdict = worker.run

      assert_equal :no_work, verdict,
                   "the loop CONTINUED through briefing_hold/briefing_ran (never exited on them)"
      assert_empty runner.verdicts, "the three briefing verdicts + the exit verdict were consumed"
      wired = runner.after_turn_set
      refute_nil wired, "the worker wired the after_turn callable at boot"
      before = passes
      wired.call
      assert_equal before + 1, passes, "the wired callable IS the loop's periodic passes"
    end
  end
end
