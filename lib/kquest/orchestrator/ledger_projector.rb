# frozen_string_literal: true

require_relative "event_publisher"
require_relative "../queries/status_snapshot"

module Kquest
  module Orchestrator
    # The projection engine (I08 §3.2 — the recorded ruling: SSE producers
    # are LEDGER PROJECTORS, not engine hooks): it polls the PG ledgers per
    # quest since an IN-PROCESS cursor (the stream is a TAIL — PG is the
    # truth; a lost cursor re-reads and the client dedupes by id) and
    # publishes the event catalog:
    #   quest.state    ← quest_lifecycle_events inserts
    #   phase.state    ← phases start/boundary/complete (the payload carries
    #                    the parity fields — EXACTLY I08 §3.2's field list)
    #   session.state  ← sessions insert / bank / pause-delivery / end
    #   tool.event     ← tool_calls rows (the event is a projection; the PG
    #                    row + transcript blob are the audit)
    #   spend.tick     ← usage_events rows (the D10 ledger's live mirror)
    #   frontier.mass  ← phase boundary snapshots
    #   subagent.run   ← the run registry's state changes (polled from
    #                    SubagentRunner#registry — no engine edit)
    # `quest.stop` comes from the runner, `assurance_alert` from the poller +
    # watcher, `watcher.bytes` from the watcher — ALL TEN catalog types flow.
    class LedgerProjector
      def initialize(conn:, publisher:, subagent_registry: nil)
        @conn = conn
        @publisher = publisher
        @subagent_registry = subagent_registry
        @cursors = {}       # ledger → [created_at, id] (in-process; a lost cursor re-reads)
        @phase_tuples = {}  # phase id → [state, attempt_no, frontier_open, frontier_mass]
        @run_states = {}    # run_id → last seen status (the registry's projection)
      end

      # One projection pass over one quest. Returns the published count.
      def project(quest_id)
        published = 0
        published += project_ledger(quest_id, :quest_lifecycle_events) do |row|
          publish_quest_state(quest_id, row)
        end
        published += project_phases(quest_id) do |row|
          publish_phase_state(quest_id, row)
        end
        published += project_ledger(quest_id, :sessions) do |row|
          publish_session_state(quest_id, row)
        end
        published += project_ledger(quest_id, :tool_calls) { |row| publish_tool_event(quest_id, row) }
        published += project_ledger(quest_id, :usage_events) { |row| publish_spend_tick(quest_id, row) }
        published + project_subagent_runs(quest_id)
      end

      private

      # The tail cursor: (created_at, id) row-comparison — new rows only, in
      # ledger order. A fresh projector re-reads from the epoch (the client
      # dedupes by id; I08 §3.3).
      def project_ledger(quest_id, table)
        cursor = @cursors[table]
        ds = @conn[table].where(quest_id: quest_id).order(:created_at, :id)
        ds = ds.where(Sequel.lit("(created_at, id) > (?::timestamptz, ?::uuid)",
                                 cursor[0], cursor[1])) if cursor
        count = 0
        last = cursor
        ds.each do |row|
          yield row
          count += 1
          last = [row.fetch(:created_at), row.fetch(:id)]
        end
        @cursors[table] = last if last
        count
      end

      # The PHASE ledger is the one table the runner AMENDS: the boundary's
      # parity snapshot lands by UPDATE — after the row's insert was already
      # tailed — so an insert-cursor would never see the boundary state (and
      # `frontier.mass` would never flow). The phase projection is therefore
      # a CHANGE projection: every pass re-reads the quest's phase rows and
      # publishes the ones whose (state, attempt_no, frontier_open,
      # frontier_mass) tuple changed since the last pass, new rows included
      # (the re-read is I08 §3.3's own law — the client dedupes by id).
      def project_phases(quest_id)
        count = 0
        @conn[:phases].where(quest_id: quest_id).order(:created_at, :id).each do |row|
          tuple = [row.fetch(:state), row.fetch(:attempt_no),
                   row.fetch(:frontier_open), row.fetch(:frontier_mass)]
          next if @phase_tuples[row.fetch(:id)] == tuple

          @phase_tuples[row.fetch(:id)] = tuple
          yield row
          count += 1
        end
        count
      end

      def publish_quest_state(quest_id, row)
        data = {"quest_id" => quest_id.to_s, "from_state" => row.fetch(:from_state),
                "to_state" => row.fetch(:to_state), "actor" => row.fetch(:actor),
                "note" => row.fetch(:note)}
        data["fingerprint"] = row.fetch(:graph_fingerprint)&.to_s if row.fetch(:to_state) == "archived"
        publish(quest_id, "quest.state", data, row)
      end

      # The parity-field payload — EXACTLY I08 §3.2's field list (the gate
      # sweep fields and the status tool show the same numbers).
      def publish_phase_state(quest_id, row)
        snapshot = Kquest::Queries::StatusSnapshot.new(conn: @conn)
        fields = snapshot.status_fields(user_id: row.fetch(:user_id), quest_id: quest_id)
        publish(quest_id, "phase.state",
                {"quest_id" => quest_id.to_s, "phase_id" => row.fetch(:id).to_s,
                 "phase_kind" => row.fetch(:kind), "attempt_no" => row.fetch(:attempt_no),
                 "phase_state" => row.fetch(:state),
                 "bare_claims" => fields[:bare_claims],
                 "unreferenced" => fields[:unreferenced],
                 "dual_arm_claims" => fields[:dual_arm_claims],
                 "decompose_remaining" => fields[:decompose_remaining],
                 "frontier_open" => row.fetch(:frontier_open) || fields[:frontier_open],
                 "frontier_mass" => row.fetch(:frontier_mass) || fields[:frontier_mass]},
                row)
        # The boundary snapshot rides its own catalog event.
        if row.fetch(:frontier_open) || row.fetch(:frontier_mass)
          publish(quest_id, "frontier.mass",
                  {"quest_id" => quest_id.to_s,
                   "frontier_open" => row.fetch(:frontier_open) || 0,
                   "frontier_total" => @conn[:frontier_entries].where(quest_id: quest_id).count,
                   "frontier_mass" => row.fetch(:frontier_mass) || 0}, row)
        end
      end

      def publish_session_state(quest_id, row)
        publish(quest_id, "session.state",
                {"quest_id" => quest_id.to_s, "session_id" => row.fetch(:id).to_s,
                 "driver" => row.fetch(:driver), "mode" => row.fetch(:mode),
                 "session_state" => row.fetch(:ended_at) ? "ended" : "live",
                 "banked?" => !row.fetch(:ended_at).nil?, "note" => nil}, row)
      end

      def publish_tool_event(quest_id, row)
        publish(quest_id, "tool.event",
                {"quest_id" => quest_id.to_s, "session_id" => row.fetch(:session_id).to_s,
                 "tool" => row.fetch(:tool), "ok" => row.fetch(:ok),
                 "error_class" => row.fetch(:error_class)}, row)
      end

      def publish_spend_tick(quest_id, row)
        publish(quest_id, "spend.tick",
                {"quest_id" => quest_id.to_s, "session_id" => row.fetch(:session_id).to_s,
                 "phase_id" => row.fetch(:phase_id).to_s, "model" => row.fetch(:model),
                 "input_tokens" => row.fetch(:input_tokens),
                 "output_tokens" => row.fetch(:output_tokens),
                 "cache_read_tokens" => row.fetch(:cache_read_tokens),
                 "cache_write_tokens" => row.fetch(:cache_write_tokens),
                 "reasoning_tokens" => row.fetch(:reasoning_tokens),
                 "cost_usd" => row.fetch(:cost_usd)&.to_s("F")}, row)
      end

      # The run registry's projection (E-SPAWN: spawn/first-result/done/
      # failed — a state change per poll, keyed by run id; no engine edit).
      def project_subagent_runs(quest_id)
        return 0 unless @subagent_registry

        count = 0
        @subagent_registry.each_value do |run|
          state = run.status.to_s
          next if @run_states[run.run_id] == state

          @run_states[run.run_id] = state
          publish(quest_id, "subagent.run",
                  {"quest_id" => quest_id.to_s,
                   "parent_session_id" => run.session_id.to_s,
                   "run_id" => run.run_id, "profile" => run.profile,
                   "band" => band_label(run.band),
                   "run_state" => state})
          count += 1
        end
        count
      end

      # The band label (the registry's band is an Array of Ranges day one —
      # the survey band partition).
      def band_label(band)
        return nil unless band.is_a?(Array)

        band.map { |b| b.is_a?(Range) ? b.to_s : b.to_s }.join(",")
      end

      def publish(quest_id, event, data, row = nil)
        @publisher.publish_quest(quest_id, event, data)
      end
    end
  end
end
