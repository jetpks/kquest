# frozen_string_literal: true

require "securerandom"

module Kquest
  module Engine
    # Nested restricted-tool loops (I04 §6, R-044): the run registry (engine
    # RUNTIME state — in-process day one; the ENTRY 4 worker-registry hosting
    # is the recorded successor seam), the spawn discipline (FM-20: spawn
    # RETURNS IMMEDIATELY — a detached reactor child; verification is ALWAYS
    # a separate status query keyed by run id; "no tool result" NEVER implies
    # "no process"), the band-survey spawn check (pairwise-disjoint bands —
    # the runner refuses non-disjoint bands loudly), the profile gate
    # (E-RESTRICT: the child's registered surface is the profile's list; a
    # profile containing `subagent_spawn` is refused AT SPAWN — no
    # recursion), and the run deadline (`engine.subagent_timeout_s`; status
    # poll `engine.subagent_status_poll_s`). Child sessions are sessions:
    # their own `sessions` row (same quest, same phase — `phase_id NOT NULL`
    # is total, I01 DR-13) so the D10 chain covers child spend by
    # construction.
    class SubagentRunner
      Run = Struct.new(:run_id, :session_id, :profile, :band, :status, :error, :started_at, :ended_at)

      attr_reader :registry

      def initialize(conn:, config:, deadline_sleeper: nil)
        @conn = conn
        @config = config
        @deadline_sleeper = deadline_sleeper # test injection
        @registry = {}
      end

      # ── the profile gate (E-RESTRICT) ──────────────────────────────────

      # A child's registered surface is the profile's list; a profile
      # containing `subagent_spawn` is refused AT SPAWN — no recursion (the
      # `operator` profile IS the full surface, spawn included, for PARENTS).
      def check_profile!(tools)
        return unless tools.include?("subagent_spawn")

        raise Error, "profile gate (E-RESTRICT): a profile containing 'subagent_spawn' is refused " \
                     "at spawn — no recursion: a subagent cannot spawn subagents; use a read-only " \
                     "profile (e.g. 'survey') for nested runs"
      end

      # ── the band-survey spawn check ────────────────────────────────────

      # Pairwise-disjoint, gap-free bands whose union equals the target id
      # range. The fixture `band-overlap` refusal TEXT is I14's tool surface;
      # the RUNNER's check refuses non-disjoint bands loudly.
      def check_bands!(bands, range:)
        ranges = bands.map { |b| (b.first..b.last) }.sort_by(&:first)
        ranges.each_cons(2) do |a, b|
          next if b.first > a.last # disjoint (touching is fine)

          raise Error, "band-survey check: bands #{a.to_a.first}..#{a.to_a.last} and " \
                       "#{b.to_a.first}..#{b.to_a.last} overlap — band workers run over DISJOINT " \
                       "numeric ranges (pairwise disjoint); repartition the target range " \
                       "#{range.first}..#{range.last}"
        end
        ranges.each_cons(2) do |a, b|
          next if b.first <= a.last + 1 # no gap

          raise Error, "band-survey check: a gap between #{a.to_a.last} and #{b.to_a.first} — " \
                       "the band union must equal the target range #{range.first}..#{range.last} " \
                       "(a merge gap is detectable, L15 blind-spot posture)"
        end
        first = ranges.first
        last = ranges.last
        return if first && last && first.first == range.first && last.last == range.last

        raise Error, "band-survey check: band union #{first&.first}..#{last&.last} does not equal " \
                     "the target range #{range.first}..#{range.last}"
      end

      # ── the spawn discipline (FM-20) ───────────────────────────────────

      # Spawn RETURNS IMMEDIATELY: the child runs on a detached reactor child
      # task; verification is ALWAYS a separate `status` query keyed by run
      # id. The child gets its own sessions row (same quest, same phase) so
      # the D10 chain covers child spend.
      def spawn(parent_session:, profile:, tools:, runnable:, band: nil)
        check_profile!(tools)

        session_id = @conn[:sessions].insert(
          user_id: parent_session.fetch(:user_id), quest_id: parent_session.fetch(:quest_id),
          phase_id: parent_session.fetch(:phase_id), mode: "autonomous",
          driver: parent_session.fetch(:driver), model: parent_session.fetch(:model)
        )
        run = Run.new(run_id: SecureRandom.uuid, session_id: session_id,
                      profile: profile, band: band, status: "running",
                      started_at: Time.now, ended_at: nil)
        @registry[run.run_id] = run

        task = Async::Task.current
        task.async do # detached: spawn returns while the child still runs
          run_child(run, runnable)
        rescue StandardError => e
          run.status = "failed"
          run.error = e.message
        ensure
          run.ended_at ||= Time.now
        end
        run.run_id
      end

      # The SEPARATE verification query (never infer child death from a
      # missing tool result): a missing run id surfaces as :unknown — the
      # POLLER retries (`engine.subagent_status_poll_s`); only the registry's
      # own terminal states mean death.
      def status(run_id)
        run = @registry[run_id]
        return :unknown unless run

        {run_id: run.run_id, session_id: run.session_id, profile: run.profile,
         band: run.band, status: run.status.to_s, error: run.error}
      end

      def deadline_s = Engine.config_value(@config, "engine.subagent_timeout_s")
      def poll_interval_s = Engine.config_value(@config, "engine.subagent_status_poll_s")

      private

      # The run deadline (`engine.subagent_timeout_s`): a past-deadline child
      # is terminated and the run marked deadline_exceeded (E-WEDGE — no
      # unbounded wait exists in the loop).
      def run_child(run, runnable)
        task = Async::Task.current
        fired = false
        timer = task.async do
          (@deadline_sleeper ? @deadline_sleeper.call(deadline_s) : sleep(deadline_s))
          fired = true
          task.cancel
        end
        begin
          runnable.call(run)
          run.status = "complete" if run.status == "running"
        rescue Async::Cancel
          raise if !fired # a real cancel is not a deadline

          run.status = "deadline_exceeded"
          run.error = "subagent run #{run.run_id} exceeded subagent_timeout_s (#{deadline_s}s) — " \
                      "terminated (E-WEDGE: every subagent run is under a deadline)"
        ensure
          timer.stop
        end
      end
    end
  end
end
