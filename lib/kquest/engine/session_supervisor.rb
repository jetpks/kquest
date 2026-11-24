# frozen_string_literal: true

require "json"
require "set"

module Kquest
  module Engine
    # Quest-scoped session lifecycle (I04 §5, R-043): the LAUNCH GATE (§5.3 —
    # transactional `SELECT … FOR UPDATE` on the quests row FIRST, then the
    # liveness check + the `sessions` insert; the refusal names the holder
    # session + driver, FM-16), the cold-boot protocol (L7 — reconstruct from
    # store-backed reads ONLY: `v_claim_closure`, `v_frontier_open`,
    # `v_unmined_sources`; no in-memory-only state), pause delivery (FM-19 —
    # at the turn boundary when the in-flight turn can complete, banked; else
    # `Chat#cancel`: CancelledError, no phantom terminal, the half-streamed
    # turn never appended, committed mutations survive), the REAPER (FM-21 —
    # orphaned `ended_at IS NULL` rows whose owner is gone get `ended_at`
    # stamped), and the ceiling menu record (FM-02/DR-06). Worker liveness
    # day one is the in-process session registry — the worker-registry
    # hosting is ENTRY 4's seam, recorded not hidden. Orchestrator-vs-
    # operator launch modes write `sessions.driver` accordingly (L13 —
    # identical tools/constraints/audit).
    class SessionSupervisor
      # Day-one liveness: the IN-PROCESS registry of live session ids — shared
      # across supervisor instances (one process, one registry); the ENTRY 4
      # worker-registry hosting is the successor seam.
      def self.registry = @registry ||= Set.new

      def self.registry_clear = @registry = nil

      def live_sessions = self.class.registry

      def initialize(conn:)
        @conn = conn
        @pause_requested = Set.new
      end

      # ── the launch gate (FM-16 / E-1W) ─────────────────────────────────

      # The gate transaction takes the quests row FOR UPDATE FIRST (the row
      # lock serializes racing launches), then the liveness check + the
      # insert. Returns the new session id.
      def launch(user_id:, quest_id:, phase_id:, mode:, driver:, model:)
        raise Error, "driver #{driver.inspect} is not a launch mode (sessions.driver is " \
                     "'orchestrator' | 'operator' — L13: identical tools/constraints/audit)" \
          unless %w[orchestrator operator].include?(driver)

        session_id = nil
        @conn.transaction do
          @conn[:quests].where(id: quest_id).for_update.first # the lock FIRST
          if (holder = live_holder(quest_id))
            raise Error.new(write_guard_refusal(quest_id: quest_id, session_id: holder[:id],
                                                driver: holder[:driver]), error_class: "WriteGuard")
          end
          session_id = @conn[:sessions].insert(
            user_id: user_id, quest_id: quest_id, phase_id: phase_id,
            mode: mode, driver: driver, model: model
          )
          self.class.registry << session_id
        end
        session_id
      end

      # A live holder: an open session row whose owning worker is alive (the
      # in-process registry day one; the ENTRY 4 worker registry is the host
      # successor). A dead holder is not a violation — the reaper owns that
      # transition.
      def live_holder(quest_id)
        @conn[:sessions].where(quest_id: quest_id, ended_at: nil).for_update.each do |row|
          return row if self.class.registry.include?(row[:id])
        end
        nil
      end

      # The frozen `write-guard` text (harness.md) with placeholders
      # substituted — the launch refusal AND the harness's per-batch recheck
      # speak the same words.
      def write_guard_refusal(quest_id:, session_id:, driver:)
        ToolHarness::WRITE_GUARD_TEXT.gsub("<quest-id>", quest_id.to_s)
                                     .gsub("<session-id>", session_id.to_s)
                                     .gsub("<driver>", driver.to_s)
      end

      # The ToolHarness's defense-in-depth recheck: raises when a DIFFERENT
      # live writer holds the quest.
      def write_guard_for(session)
        quest_id = session.fetch(:quest_id)
        proc do
          holder = live_holder(quest_id)
          next if holder.nil? || holder[:id] == session.fetch(:id)

          raise Error.new(write_guard_refusal(quest_id: quest_id, session_id: holder[:id],
                                              driver: holder[:driver]), error_class: "WriteGuard")
        end
      end

      # ── the cold-boot protocol (L7) ────────────────────────────────────

      # Reconstruct from store-backed reads ONLY — the closure status, the
      # open frontier, the unmined sources. No in-memory-only state exists.
      def cold_boot(quest_id:)
        {
          claims: @conn["SELECT * FROM v_claim_closure WHERE quest_id = ?", quest_id].all,
          frontier: @conn["SELECT * FROM v_frontier_open WHERE quest_id = ?", quest_id].all,
          unmined_sources: @conn["SELECT * FROM v_unmined_sources WHERE quest_id = ?", quest_id].all
        }
      end

      # ── pause (FM-19 / E-PAUSE) ────────────────────────────────────────

      # An operator pause request: delivered at the NEXT TURN BOUNDARY (when
      # the in-flight turn can complete, banked) unless delivered mid-turn by
      # `cancel_now!`. Steering lands only through pause, never while
      # running (D5).
      def request_pause!(quest_id) = (@pause_requested << quest_id)

      def pause_requested?(quest_id) = @pause_requested.include?(quest_id)

      # Mid-turn delivery: `Chat#cancel` — CancelledError with NO phantom
      # terminal; the half-streamed turn is never appended; committed
      # mutations survive.
      def cancel_now!(chat) = chat.cancel

      # The boundary delivery: the ledgered `active → paused` transition
      # (quests.state + a quest_lifecycle_events row — I02's ledgered
      # transition) + the session banked.
      def pause_quest!(user_id:, quest_id:, actor: "operator", note: nil)
        @conn.transaction do
          quest = @conn[:quests].where(id: quest_id).for_update.first
          raise Error, "quest #{quest_id} is not active (state #{quest[:state].inspect}) — " \
                       "active → paused is a ledgered transition from active" if quest.nil? || quest[:state] != "active"

          @conn[:quests].where(id: quest_id).update(state: "paused")
          @conn[:quest_lifecycle_events].insert(
            user_id: user_id, quest_id: quest_id,
            from_state: "active", to_state: "paused", actor: actor,
            occurred_at: Time.now, note: note
          )
        end
        @pause_requested.delete(quest_id)
        nil
      end

      # ── the reaper (FM-21) ─────────────────────────────────────────────

      # Orphaned open sessions (ended_at IS NULL, owner gone — not in the
      # live registry) get ended_at stamped. After reaping, the launch gate
      # is open again — the cold-boot restart path.
      def reap_orphans!(quest_id: nil)
        reaped = []
        scope = @conn[:sessions].where(ended_at: nil)
        scope = scope.where(quest_id: quest_id) if quest_id
        scope.each do |row|
          next if self.class.registry.include?(row[:id])

          @conn[:sessions].where(id: row[:id]).update(ended_at: Time.now)
          reaped << row[:id]
        end
        reaped
      end

      # ── the ceiling menu record (FM-02 / DR-06) ────────────────────────

      # At the hard ceiling the session ends at the boundary and the durable
      # state names the two options — A swap-at-the-wall, B
      # compact-and-continue (the runtime operator decision; the interactive
      # surface over that state is ENTRY 5's).
      def end_at_ceiling!(session_id:, phase_id:, menu_record:)
        now = Time.now
        @conn[:phases].where(id: phase_id)
                      .update(result: Sequel.lit("coalesce(result, '{}'::jsonb) || ?::jsonb",
                                                 JSON.generate(ceiling: menu_record)))
        @conn[:sessions].where(id: session_id, ended_at: nil).update(ended_at: now)
        self.class.registry.delete(session_id)
        menu_record
      end

      # Bank the session (the boundary exit path): ended_at stamped, the
      # liveness registry released.
      def bank_session!(session_id:)
        @conn[:sessions].where(id: session_id, ended_at: nil).update(ended_at: Time.now)
        self.class.registry.delete(session_id)
        nil
      end
    end
  end
end
