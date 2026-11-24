# frozen_string_literal: true

require_relative "worker_registry"

module Kquest
  module Orchestrator
    # The launcher loop (I08 DR-08 ruling A): a tiny periodic loop over the
    # lifecycle state that keeps EXACTLY ONE worker process per ACTIVE quest —
    # it boots a `bin/quest-worker.rb <quest_id>` child for each quest in
    # `active` without a live worker (registry-verified, never pidfile-guessed),
    # reaps exited children, and hosts the assurance poller (I08 §3.4: ONE
    # global pass per cadence — the cross-quest predicates
    # `tw_hub_divergence`/`tw_fingerprint_drift` would double-fire from a
    # per-quest host).
    #
    # IO seams are constructor-injected (the landed RetryGovernor sleeper
    # pattern): `spawner:` boots the child process, `sleeper:` paces the loop,
    # so the one-worker-per-active-quest law is unit-tested keylessly.
    class Launcher
      TICK_S = 10

      # THE decision, as a pure function: which quests need a worker booted —
      # the quests in `active` whose quest_id no live worker entry claims.
      def self.workers_to_boot(quests:, live:)
        live_quest_ids = live.filter_map { |w| w[:value]["quest_id"] }
        quests.select { |q| q[:state] == "active" && !live_quest_ids.include?(q[:id].to_s) }
      end

      # conn: the Sequel connection; registry: a WorkerRegistry (this
      # launcher's own heartbeat entry); poller: the assurance poller
      # (optional — hosted here per the recorded ruling); spawner/sleeper: the
      # IO seams (defaults spawn the quest-worker bin / sleep). The spawner
      # returns a child pid (Integer) the reaper can wait on non-blockingly.
      def initialize(conn:, registry:, poller: nil, spawner: nil, sleeper: nil,
                     tick_s: TICK_S)
        @conn = conn
        @registry = registry
        @poller = poller
        @spawner = spawner || ->(quest_id) {
          bin = File.expand_path("../../../bin/quest-worker.rb", __dir__)
          Process.spawn(RbConfig.ruby, bin, quest_id.to_s)
        }
        @sleeper = sleeper || ->(s) { sleep s }
        @tick_s = tick_s
        @children = {} # quest_id => child pid
      end

      # One launcher tick: boot missing workers, reap exited children, run the
      # assurance pass. Returns the booted quest ids (the tick's observable).
      def tick
        booted = boot_missing_workers!
        reap_exited_children!
        @poller&.pass
        booted
      end

      # The loop. Runs until the supervisor stops it (DR-08: falcon supervises
      # this service alongside kquest.web).
      def run
        loop do
          tick
          @sleeper.call(@tick_s)
        end
      end

      private

      def boot_missing_workers!
        quests = @conn[:quests].where(state: "active").select(:id, :state).to_a
        live = @registry.live_workers
        self.class.workers_to_boot(quests: quests, live: live).map do |quest|
          @children[quest.fetch(:id)] = @spawner.call(quest.fetch(:id))
          quest.fetch(:id)
        end
      end

      # Reap exited children: waitpid NOHANG per pid — a live child returns
      # nil (stay in the map), an exited child is reaped and dropped; the
      # next tick re-boots if the quest is still active without a live worker
      # (the registry is the truth: a crashed worker's key expires in ≤ 30 s).
      def reap_exited_children!
        @children.each do |quest_id, pid|
          reaped =
            begin
              pid == Process.wait(pid, Process::WNOHANG)
            rescue Errno::ECHILD
              true
            end
          @children.delete(quest_id) if reaped
        end
        nil
      end
    end
  end
end
