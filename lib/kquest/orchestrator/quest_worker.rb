# frozen_string_literal: true

require_relative "worker_registry"
require_relative "reaper"
require_relative "phase_runner"
require_relative "transcript_watcher"
require_relative "ledger_projector"
require_relative "../engine/session_supervisor"

module Kquest
  module Orchestrator
    # The quest worker process (I08 §2.1/§2.7, DR-02 ruling A): ONE worker
    # for ONE active quest (the dev shape, I08 §6: "one terminal per active
    # quest"). Boots cold (L7), registers in the worker registry, refuses to
    # run unless the quest is `active`, exits when the quest leaves `active`
    # (exit is safe: nothing is live; resume is a fresh worker — L7).
    #
    # Hosts: the phase runner loop, the transcript watcher (the byte-accurate
    # census), the ledger projector + event publisher, and the session reaper
    # pass (boot + periodic). The ASSURANCE POLLER is NOT hosted here — the
    # launcher hosts it (the recorded ruling: the cross-quest predicates
    # fire once globally).
    #
    # The §8 amendment's loop half: the runner's briefing executor is wired
    # with THIS loop's periodic passes after EVERY exchange turn (per-turn
    # SSE visibility without a second thread — Grounds §4.4), and the loop
    # CONTINUES on `:briefing_hold`/`:briefing_ran` — the worker stays up
    # while the operator session is open (the agent half of the chat).
    class QuestWorker
      attr_reader :registry, :watcher

      def initialize(conn:, quest_id:, registry:, supervisor:, runner:, watcher: nil,
                     projector: nil, reaper: nil, sleeper: nil, tick_s: 1)
        @conn = conn
        @quest_id = quest_id
        @registry = registry
        @supervisor = supervisor
        @runner = runner
        @watcher = watcher
        @projector = projector
        @reaper = reaper || Reaper.new(conn: conn, liveness: registry)
        @sleeper = sleeper || ->(s) { sleep s }
        @tick_s = tick_s
      end

      # The worker loop. Returns the exit verdict:
      #   :not_active          — the quest is not `active` (the boot refusal)
      #   :awaiting_briefing   — active, but the briefing has not landed
      #   :quest_done/:paused/:stopped — the quest left `active` at a boundary
      #   :no_work             — the runner has nothing to do
      #   (:briefing_hold/:briefing_ran LOOP — the runner serves the open
      #    operator session; the worker stays up, never exits on them)
      def run
        quest = @conn[:quests].where(id: @quest_id).first
        return :not_active unless quest && quest.fetch(:state) == "active"

        @registry.register!
        boot_passes
        # The §8 wiring: the runner's briefing executor fires THIS loop's
        # periodic passes after EVERY exchange turn (Grounds §4.4). Guarded so
        # injected double/stub runners stay compatible.
        @runner.after_turn = -> { periodic_passes } if @runner.respond_to?(:after_turn=)
        loop do
          @registry.heartbeat!(session_ids: live_session_ids)
          verdict = @runner.run_next(@quest_id)
          return finish(verdict) unless continue?(verdict)

          periodic_passes
          @sleeper.call(@tick_s)
        end
      end

      private

      # The runner keeps working while phases advance; every lifecycle
      # terminal (and the awaiting-briefing idle state) exits the worker. The
      # §8 verdicts LOOP: an open operator session is a live steering surface
      # — hold while nothing is enqueued (:briefing_hold), keep serving turns
      # (:briefing_ran). Every other verdict's law is unchanged.
      def continue?(verdict)
        %i[ran entered briefing_hold briefing_ran].include?(verdict)
      end

      def live_session_ids
        @conn[:sessions].where(quest_id: @quest_id, ended_at: nil).select_map(:id)
      end

      def boot_passes
        @reaper.sweep(quest_id: @quest_id)
        @projector&.project(@quest_id)
        @watcher&.census
        nil
      end

      def periodic_passes
        @reaper.sweep(quest_id: @quest_id)
        @projector&.project(@quest_id)
        @watcher&.census
        nil
      end

      def finish(verdict)
        @registry.unregister!
        verdict
      end
    end
  end
end
