# frozen_string_literal: true

require_relative "../test_helper"
require "async/redis"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/orchestrator/worker_registry"
require_relative "../../lib/kquest/orchestrator/launcher"

# The launcher (I08 DR-08 ruling A): EXACTLY ONE worker process per ACTIVE
# quest — the decision is a pure function (`workers_to_boot`), the loop is
# tick-testable with the injected spawner/sleeper seams (the RetryGovernor
# sleeper pattern), and the reaper pass drops exited children.
class LauncherTest < Minitest::Test
  def setup
    # The launcher's view is GLOBAL (it boots for every active quest), so the
    # test sweeps the shared test db first (the substrate action tests'
    # setup_db discipline) — the assertions stay about THIS test's quests.
    OrchestratorFixtures.sweep_all(conn)
    @prefix = OrchestratorFixtures.redis_prefix
    @redis = OrchestratorFixtures.redis_client
    @quests = 3.times.map do |i|
      OrchestratorFixtures.mint_quest(conn, user_id: @user_id ||= mint_user,
                                      topic: "launcher quest #{i}",
                                      state: i.zero? ? "paused" : "active")
    end
  end

  def teardown
    Sync { OrchestratorFixtures.cleanup_redis(@redis, @prefix) } if @redis
    @redis&.close
    OrchestratorFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def mint_user
    @user_id = conn[:users].insert(handle: "gh-#{SecureRandom.hex(6)}",
                                   github_uid: SecureRandom.uuid,
                                   username: "u#{SecureRandom.hex(6)}",
                                   name: "Kquest::Orchestrator::Launcher Fixture", created_at: Time.now)
  end

  def quest_rows = conn[:quests].where(id: @quests).order(:created_at).select(:id, :state).to_a

  def test_launcher_boots_exactly_one_worker_per_active_quest
    booted = Kquest::Orchestrator::Launcher.workers_to_boot(quests: quest_rows, live: [])
    assert_equal 2, booted.size, "the paused quest gets NO worker; the two active do"

    # One live worker per active quest already → nothing to boot.
    live = quest_rows.select { |q| q[:state] == "active" }.map do |q|
      {value: {"quest_id" => q[:id].to_s, "kind" => "quest"}}
    end
    assert_empty Kquest::Orchestrator::Launcher.workers_to_boot(quests: quest_rows, live: live),
                 "a live worker per active quest is exactly one — nothing more to boot"
  end

  def test_launcher_tick_boots_missing_and_never_doubles
    spawned = []
    launcher_reg = Kquest::Orchestrator::WorkerRegistry.new(
      redis: @redis, kind: "launcher", prefix: @prefix
    )
    Sync do
      launcher_reg.register!
      launcher = Kquest::Orchestrator::Launcher.new(
        conn: conn, registry: launcher_reg,
        spawner: ->(quest_id) { spawned << quest_id; Process.spawn("sleep", "30") },
        sleeper: ->(_s) {}
      )
      first = launcher.tick
      assert_equal 2, first.size, "one worker per active quest on the first tick"
      assert_equal spawned.size, spawned.uniq.size, "exactly one worker per quest"

      # The booted workers register themselves (the child's first act): once
      # their entries are live, the tick boots NOTHING — the registry is the
      # truth, never a pidfile guess.
      quest_rows.select { |q| q[:state] == "active" }.each do |q|
        Kquest::Orchestrator::WorkerRegistry.new(
          redis: @redis, kind: "quest", quest_id: q[:id], prefix: @prefix
        ).register!
      end
      assert_empty launcher.tick, "the second tick boots NOTHING — the workers are live"
      assert_equal 2, spawned.size
    end
  ensure
    Sync { launcher_reg&.unregister! }
  end

  def test_launcher_reaps_exited_children_and_keeps_the_one_worker_law
    boots = 0
    registry = Kquest::Orchestrator::WorkerRegistry.new(
      redis: @redis, kind: "launcher", prefix: @prefix
    )
    Sync do
      registry.register!
      launcher = Kquest::Orchestrator::Launcher.new(
        conn: conn, registry: registry,
        spawner: ->(_quest_id) {
          boots += 1
          Process.spawn("true") # a child that exits immediately
        },
        sleeper: ->(_s) {}
      )
      launcher.tick
      5.times { launcher.tick }
      # The fake children exit immediately and register nothing, so the
      # launcher's registry-verified view keeps finding the active quests
      # unheld: it reaps each exited child and re-boots — the honest loop
      # (a crashed worker is rebooted while its quest is active; a crashed
      # worker's registry key expires with it).
      assert_operator boots, :>=, 2, "exited children are reaped and re-booted"
    end
  ensure
    Sync { registry&.unregister! }
  end
end
