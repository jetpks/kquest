# frozen_string_literal: true

module Kquest
  module Orchestrator
    # The reaper sweep (I04 DR-05, FM-21; I08 §2.3): sessions with
    # `ended_at IS NULL` whose session id no live worker claims get `ended_at`
    # stamped — the ledgered sweep, re-hosted from the landed
    # `SessionSupervisor#reap_orphans!` logic against the REGISTRY liveness
    # source (the quest worker runs it at boot + periodically; the launcher's
    # workers each sweep their own quest). After reaping, the launch gate is
    # open — the cold-boot restart path (L7).
    #
    # The liveness source is the port (constructor-injected): the redis
    # `WorkerRegistry` in the hosted shape, the landed in-process Set in the
    # unit tests. MUTATES (this is the consequence half — the signal path
    # never does).
    #
    # The I18 held-by-row clarification (Grounds §4.1/§5.5): OPERATOR-driver
    # sessions are NEVER reaped — the row IS the holder (`ended_at IS NULL`),
    # the human's sign-off (`end_session!`) is the only end (DR-04 ruling A;
    # I06 §2.2: "the operator is present BY DEFINITION"). Cross-process
    # liveness cannot see a human's session; an operator session's open row
    # is the intent, and the briefing chat + console render it (with the
    # sign-off door) honestly. An unclaimed ORCHESTRATOR row still reaps.
    class Reaper
      def initialize(conn:, liveness:)
        @conn = conn
        @liveness = liveness
      end

      # Stamp `ended_at` on every open session no live worker claims —
      # EXCEPT operator-driver rows (held-by-row; see above). quest_id scopes
      # the sweep to one quest (the quest worker's boot pass); nil sweeps all
      # (the launcher's global pass). Returns the reaped ids.
      def sweep(quest_id: nil)
        reaped = []
        scope = @conn[:sessions].where(ended_at: nil)
        scope = scope.where(quest_id: quest_id) if quest_id
        scope.each do |row|
          next if row.fetch(:driver) == "operator"
          next if @liveness.session_live?(row.fetch(:id))

          @conn[:sessions].where(id: row.fetch(:id)).update(ended_at: Time.now)
          reaped << row.fetch(:id)
        end
        reaped
      end
    end
  end
end
