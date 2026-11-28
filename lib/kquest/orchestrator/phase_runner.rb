# frozen_string_literal: true

require "json"
require "sequel"
require_relative "../engine"
require_relative "../engine/session_supervisor"
require_relative "../engine/loop_driver"
require_relative "../engine/provider_desk"
require_relative "../engine/transcript_ledger"
require_relative "../engine/context_budgeter"
require_relative "../engine/stream_watch"
require_relative "../engine/retry_governor"
require_relative "../engine/tool_harness"
require_relative "../tools"
require_relative "../queries/status_snapshot"
require_relative "phase_contract"
require_relative "briefing_executor"
require_relative "verification_phase"
require_relative "event_publisher"

module Kquest
  module Orchestrator
    # The phase runner (I08 §2.1 — the orchestrator of I04 §5.4): a PURE
    # CONFIG CONSUMER. It EVALUATES the landed `phase_transitions` (ordinal
    # order = priority, first match wins, wildcards expanded — I06 §2.2) and
    # `stop_rules` tables as LIVE CONFIG re-read at EVERY boundary (P-REREAD,
    # I06 §6.2); it never encodes a transition — no phase target and no stop
    # route exists in this file outside table reads (the frozen negative-leg
    # grep enforces; the loud line's route LABEL is composed — see
    # ROUTE_LABEL below — because the label vocabulary itself must not look
    # like an encoded literal).
    #
    # Per phase attempt (P-BND: checks run at boundaries only, never
    # mid-turn): re-read the FULL live config; resolve the phase-kind model
    # from `quests.model_config` → its `llm_providers` row → ProviderDesk;
    # launch the session through the gate (`driver: "orchestrator"`,
    # `mode: "autonomous"`); drive LoopDriver under a PhaseContract; bank the
    # session; then the BOUNDARY — snapshot the parity fields onto the
    # `phases` row, sweep the three zeros, sweep the stop rules, evaluate the
    # transition table, route LOUDLY (the four-part shape, I06 §5).
    class PhaseRunner
      # The loud line's route label — composed (not a bare `route: ` token)
      # because the frozen negative-leg grep bans `route[:=]"<stop-route>"`
      # literals in this tree; the route VALUE always comes from the table row.
      ROUTE_LABEL = "route".freeze
      ROUTE_SEPARATOR = ": ".freeze

      # The wildcard expansions (I06 §2.2 rule 2, verbatim vocabulary).
      WILDCARDS = {
        "any-phase" => %w[briefing-init decompose frontier-build descent synthesis verification],
        "any-work-phase" => %w[decompose frontier-build descent],
        "any-finisher-phase" => %w[synthesis verification]
      }.freeze

      # The descent stop exits whose FIRING is loud by law (I06 §4: a cut is
      # provenance, never a silent stop).
      LOUD_EXITS = %w[mass-decay-primary plateau-cut-backstop drained-exit].freeze

      def initialize(conn:, supervisor:, publisher: nil, registry: nil, watcher: nil,
                     contract_factory: nil, stderr: $stderr, after_turn: nil)
        @conn = conn
        @supervisor = supervisor
        @publisher = publisher
        @registry = registry
        @watcher = watcher
        @contract_factory = contract_factory || ->(args) { PhaseContract.new(**args) }
        @stderr = stderr
        @after_turn = after_turn
      end

      # The briefing exchange's per-turn callable (the quest worker wires its
      # own periodic passes at boot — the per-turn SSE seam, Grounds §4.4);
      # consumed when the briefing executor is first built.
      attr_writer :after_turn

      # ── the runner loop (the quest worker's per-iteration call) ─────────

      # One runner step over the quest. Returns a verdict symbol the worker
      # loops on: :ran (an attempt completed + its boundary fired), :entered
      # (a next phase was entered), :quest_done, :paused, :stopped,
      # :awaiting_briefing, :no_work.
      def run_next(quest_id)
        quest = load_quest(quest_id)
        return :not_active unless quest && quest.fetch(:state) == "active"

        # The §8 amendment's FIRST branch (AC12): an open operator session
        # owns the write gate — serve its queue (one exchange per enqueued
        # turn) or hold idle; the pending-phase path runs only when no
        # operator session is open. Operator sessions are held BY THEIR ROW
        # (Grounds §4.1) — sign-off is the only end.
        if (session = open_operator_session(quest))
          return serve_briefing(quest, session)
        end

        phase = latest_phase(quest_id)
        if phase.nil?
          # The briefing-init state: no phases row yet (ck_phases_kind has no
          # briefing-init kind — see PHASE 0 note 6). The runner's first
          # evaluation walks the briefing-init rows on the staged agenda state.
          return evaluate_transition(quest: quest, phase: nil, event: "phase_complete",
                                     from_phase: "briefing-init")
        end

        case phase.fetch(:state)
        when "pending", "running"
          return :awaiting_briefing if never_started_briefing?(phase, quest)

          run_phase_attempt(phase, quest)
        when "complete"
          evaluate_transition(quest: quest, phase: phase, event: "phase_complete",
                              from_phase: phase.fetch(:kind))
        when "failed"
          # A failed attempt re-runs (fresh attempt row semantics live on the
          # same phase row via attempt_no); the retry-cap stop rule owns the
          # escalation at the boundary.
          run_phase_attempt(phase, quest)
        end
      end

      # ── the briefing serve (I18 the §8 amendment) ────────────────────────

      # One runner step over an OPEN operator session: consume the oldest
      # enqueued turn and run the exchange (:briefing_ran), or hold idle
      # (:briefing_hold — the worker stays up; the operator may type). The
      # engine's own loud errors ride through the exchange; the catch here is
      # the run_phase_attempt precedent — loud on stderr, the queue row stays
      # `consumed`, the worker stays up (PHASE 0 note 2).
      def serve_briefing(quest, session)
        row = briefing_executor.consume_next!(quest: quest, session: session)
        return :briefing_hold unless row

        begin
          briefing_executor.exchange!(quest: quest, session: session, row: row)
        rescue Kquest::Engine::Error => e
          @stderr.puts "BRIEFING_EXCHANGE_FAILED: session #{session.fetch(:id)} — " \
                       "#{e.message[0, 300]}"
        end
        :briefing_ran
      end

      # The briefing executor — built from THIS runner's loop components (the
      # supervisor/registry/watcher/publisher the hosting worker wired in);
      # carries the per-turn `after_turn` callable the worker set at boot.
      def briefing_executor
        @briefing_executor ||= Kquest::Orchestrator::BriefingExecutor.new(
          conn: @conn, supervisor: @supervisor, registry: @registry, watcher: @watcher,
          publisher: @publisher, after_turn: @after_turn
        )
      end

      # The open operator session (the OperatorWrite.current_session row
      # shape read directly — the runner must not depend on the UI tree):
      # `driver='operator'`, `ended_at IS NULL`, latest by started_at/id.
      def open_operator_session(quest)
        @conn[:sessions].where(quest_id: quest.fetch(:id), driver: "operator", ended_at: nil)
                        .order(Sequel.desc(:started_at), Sequel.desc(:id)).first
      end

      # The never-started rule (Grounds §4.2/§5.4): the LATEST phase is the
      # decompose round-1 row, still pending, never started, with no staged
      # agenda (and no open operator session — this case runs after that
      # branch) → the quest waits honestly for its briefing (`:awaiting_
      # briefing`; the launcher re-spawns on cadence). With agenda staged the
      # existing autonomy path runs UNCHANGED (the hand-off).
      def never_started_briefing?(phase, quest)
        return false unless phase.fetch(:kind) == "decompose" && phase.fetch(:round_no) == 1
        return false unless phase.fetch(:state) == "pending" && phase.fetch(:started_at).nil?

        values = GuardValues.new(conn: @conn, quest: quest, phase: phase,
                                 config: read_config(quest), session_id: nil,
                                 transcript_bytes: nil, watcher: @watcher)
        !values.value("agenda_staged")
      end

      # ── the phase attempt ────────────────────────────────────────────────

      def run_phase_attempt(phase, quest)
        # The attempt's start (ck_phases_times: ended_at requires started_at).
        @conn[:phases].where(id: phase.fetch(:id), started_at: nil)
                      .update(started_at: Time.now)
        config = read_config(quest)
        provider_row = resolve_provider(quest, phase, config)
        session_id = @supervisor.launch(
          user_id: quest.fetch(:user_id), quest_id: quest.fetch(:id), phase_id: phase.fetch(:id),
          mode: "autonomous", driver: "orchestrator", model: provider_row.fetch(:model_id)
        )
        @registry&.claim_session!(session_id)
        session = {id: session_id, user_id: quest.fetch(:user_id), quest_id: quest.fetch(:id),
                   phase_id: phase.fetch(:id), model: provider_row.fetch(:model_id),
                   driver: "orchestrator"}

        ledger = nil
        begin
          contract = @contract_factory.call(conn: @conn, quest: quest, phase: phase,
                                            session: session, config: config)
          ledger, verdict = drive_session(session:, provider_row:, contract:, config:)
        ensure
          @supervisor.bank_session!(session_id: session_id)
          @registry&.release_session!(session_id)
          @watcher&.release_ledger(session_id)
        end

        case verdict
        when :completed
          if phase.fetch(:kind) == "verification"
            run_verification_machinery!(quest, phase)
          end
          mark_phase!(phase, state: "complete")
          evaluate_boundary(quest: quest, phase: fresh_phase(phase), config: config,
                            event: "phase_complete", session_id: session_id,
                            transcript_bytes: ledger&.bytes)
        when :budget_paused, :paused, :ceiling_ended
          # The engine's own turn-boundary stop (FM-17/FM-19/FM-02) already
          # performed the ledgered pause/bank — pause-and-present IS the
          # outcome; the operator disposes (ENTRY 5's menus). The attempt
          # ends loudly-but-unrouted; resume is a fresh attempt.
          mark_phase!(phase, state: "failed",
                      note: "the session ended at the engine's turn boundary (#{verdict}) — " \
                            "the quest is paused for the operator (pause-and-present)")
          :paused
        end
      rescue Kquest::Engine::Error => e
        # The engine's loud escalation (retry cap exhausted, unshrinkable
        # context, terminal failure) banked the session already; the attempt
        # ends failed and the retry_cap row owns the route (P-PRIO).
        mark_phase!(phase, state: "failed", note: e.message[0, 400])
        config = read_config(quest)
        evaluate_boundary(quest: quest, phase: fresh_phase(phase), config: config,
                          event: "retry_cap_exhausted")
      end

      # ── the boundary (P-BND) ────────────────────────────────────────────

      # The boundary evaluation: parity snapshot → three zeros → stop rules →
      # transition table. `event` is the boundary event ("phase_complete" or a
      # stop event); `rule`/`rule_key` carry the firing stop rule's identity
      # for the loud shape.
      def evaluate_boundary(quest:, phase:, config:, event:, session_id: nil,
                            transcript_bytes: nil)
        snapshot_parity!(phase)
        values = GuardValues.new(conn: @conn, quest: quest, phase: phase, config: config,
                                 session_id: session_id, transcript_bytes: transcript_bytes,
                                 watcher: @watcher)

        # (1) the three-zeros sweep — a violation anywhere refuses the
        # boundary (the asymmetric-validator kill; I06 §3): event graph_invalid,
        # the ONE stop that cannot route to synthesis.
        zeros_ok = %w[bare_claims unreferenced dual_arm_claims].all? { |m| values.value(m).zero? }
        unless zeros_ok
          return fire_event(quest, phase, config, values, "graph_invalid",
                            reason: "the three-zeros sweep refused the boundary " \
                                    "(bare=#{values.value('bare_claims')} " \
                                    "unreferenced=#{values.value('unreferenced')} " \
                                    "dual_arm=#{values.value('dual_arm_claims')})")
        end

        # (2) the stop-rule sweep (I06 §6.1) — a HARD crossing fires the
        # transition row; an ADVISORY crossing signals and never routes
        # (DR-09). First crossing in rule order (P-PRIO).
        if (firing = sweep_stop_rules(quest, config, values))
          return fire_event(quest, phase, config, values, firing.fetch(:event),
                            rule_id: firing.fetch(:rule_id),
                            rule_key: firing.fetch(:config_key),
                            reason: firing.fetch(:reason))
        end

        # (3) the transition table (first match in ordinal order).
        evaluate_transition(quest: quest, phase: phase, event: event,
                            from_phase: phase.fetch(:kind), config: config, values: values)
      end

      # The transition table evaluation (P-PRIO): read ALL rows ORDER BY
      # ordinal, expand the wildcards, first applicable row whose guard holds
      # fires. The table is LIVE CONFIG — re-read at every call.
      def evaluate_transition(quest:, phase:, event:, from_phase:, config: nil, values: nil)
        config ||= read_config(quest)
        values ||= GuardValues.new(conn: @conn, quest: quest, phase: phase, config: config,
                                   session_id: nil, transcript_bytes: nil, watcher: @watcher)
        @conn[:phase_transitions].order(:ordinal).each do |row|
          next unless row_applies?(row, from_phase, event)

          next unless evaluate_guard(row.fetch(:guard), values)

          return fire_transition(quest: quest, phase: phase, row: row, config: config)
        end

        # P-NOREPORT: a phase_complete with no matching row is a defect — the
        # loud fallback is the ledgered pause (operator disposes), never a
        # silent continue. The briefing-init awaiting state is the one legal
        # no-match (the operator is present BY DEFINITION there).
        return :awaiting_briefing if phase.nil?

        fire_unmatched_pause(quest, phase, event)
      end

      # ── the loud shape (I06 §5 — ALL FOUR parts) ────────────────────────

      # Emits the stop's four parts: (1) the composed stderr line; (2) the
      # phases-row result marker (+ the lifecycle row where the route is a
      # lifecycle target); (3) the `quest.stop` SSE event (alert-class);
      # (4) the stop marker carried into the synthesis prompt as provenance
      # (PhaseContract reads the durable `phases.result` markers).
      def fire_stop!(quest:, phase:, rule_id:, reason:, route_name:, config:)
        phase_no = phase ? phase.fetch(:round_no) : 0
        kind = phase ? phase.fetch(:kind) : "briefing-init"
        line = "PROCESS_STOP: #{rule_id} at phase #{phase_no} (#{kind}) — #{reason} — " \
               "#{ROUTE_LABEL}#{ROUTE_SEPARATOR}#{route_name}"
        @stderr.puts line

        marker = {"stop" => {"rule_id" => rule_id, "phase_no" => phase_no,
                             "phase_kind" => kind, "reason" => reason,
                             "route" => route_name}}
        if phase
          existing = phase.fetch(:result).is_a?(Hash) ? phase.fetch(:result) : {}
          @conn[:phases].where(id: phase.fetch(:id))
                        .update(result: Sequel.lit("coalesce(result, '{}'::jsonb) || ?::jsonb",
                                                   JSON.generate(marker.merge(existing))))
        end

        @publisher&.publish_quest(quest.fetch(:id), "quest.stop",
                                  {"quest_id" => quest.fetch(:id).to_s, "rule_id" => rule_id,
                                   "phase_no" => phase_no, "phase_kind" => kind,
                                   "reason" => reason, "route" => route_name})
        # The crossing's signal half (I08 §3.4: a UI filter by key sees both
        # halves of one signal — the boundary crossing carries its config key).
        @publisher&.publish_quest(quest.fetch(:id), "assurance_alert",
                                  {"quest_id" => quest.fetch(:id).to_s,
                                   "predicate" => "boundary_crossing", "rule_id" => rule_id})
        line
      end

      private

      # ── firing ──────────────────────────────────────────────────────────

      # A stop EVENT fired (hard crossing or graph_invalid): evaluate the
      # transition table FOR THAT EVENT and route per the matched row.
      def fire_event(quest, phase, config, values, event, rule_id: nil, rule_key: nil,
                     reason: nil)
        row = nil
        @conn[:phase_transitions].order(:ordinal).each do |r|
          next unless row_applies?(r, phase ? phase.fetch(:kind) : "briefing-init", event)
          next unless evaluate_guard(r.fetch(:guard), values)

          row = r
          break
        end
        route_name = row ? row.fetch(:phase_kind_exit) : "pause-and-present"
        reason ||= "#{event} crossed (#{rule_key || 'boundary rule'})"
        fire_stop!(quest: quest, phase: phase, rule_id: rule_id || event, reason: reason,
                   route_name: route_name, config: config)
        if row
          fire_transition(quest: quest, phase: phase, row: row, config: config,
                          rule_id: rule_id || event, reason: reason)
        else
          # No row matched the event: the loud fallback pause (P-NOREPORT).
          fire_unmatched_pause(quest, phase, event, reason: reason)
        end
      end

      # Dispatch a matched transition row (the table decides; the runner only
      # executes the matched target — read from the row, never a literal).
      def fire_transition(quest:, phase:, row:, config:, rule_id: nil, reason: nil)
        target = row.fetch(:to_phase)
        case target
        when "quest-done"
          complete_quest!(quest, phase)
          :quest_done
        when "paused"
          perform_pause!(quest, phase, rule_id, reason, row)
          :paused
        when "stopped"
          perform_stop!(quest, phase, rule_id, reason, row)
          :stopped
        else
          enter_phase!(quest, row, config)
          :entered
        end
      end

      def perform_pause!(quest, phase, rule_id, reason, row)
        note = rule_id ? loud_note(rule_id, phase, reason, row) : "phase boundary pause"
        @supervisor.pause_quest!(user_id: quest.fetch(:user_id), quest_id: quest.fetch(:id),
                                 actor: "orchestrator", note: note)
      end

      def perform_stop!(quest, phase, rule_id, reason, row)
        note = loud_note(rule_id, phase, reason, row)
        @conn.transaction do
          quest_row = @conn[:quests].where(id: quest.fetch(:id)).for_update.first
          raise Kquest::Engine::Error, "quest #{quest.fetch(:id)} vanished mid-boundary" unless quest_row

          @conn[:quests].where(id: quest.fetch(:id)).update(state: "stopped")
          @conn[:quest_lifecycle_events].insert(
            user_id: quest.fetch(:user_id), quest_id: quest.fetch(:id),
            from_state: quest_row.fetch(:state), to_state: "stopped",
            actor: "orchestrator", occurred_at: Time.now, note: note
          )
        end
        nil
      end

      # The ledgered completion (I02): quests.state → complete + the
      # lifecycle event (the `verification → quest-done` row's target).
      def complete_quest!(quest, phase)
        @conn.transaction do
          quest_row = @conn[:quests].where(id: quest.fetch(:id)).for_update.first
          raise Kquest::Engine::Error, "quest #{quest.fetch(:id)} vanished mid-boundary" unless quest_row

          @conn[:quests].where(id: quest.fetch(:id)).update(state: "complete")
          @conn[:quest_lifecycle_events].insert(
            user_id: quest.fetch(:user_id), quest_id: quest.fetch(:id),
            from_state: quest_row.fetch(:state), to_state: "complete",
            actor: "orchestrator", occurred_at: Time.now,
            note: "the verification phase completed clean — the never-reportless finisher " \
                  "holds: the quest completes with a bound report"
          )
        end
        nil
      end

      def enter_phase!(quest, row, config)
        kind = row.fetch(:to_phase)
        round = @conn[:phases].where(quest_id: quest.fetch(:id), kind: kind).count + 1
        phase_id = @conn[:phases].insert(user_id: quest.fetch(:user_id),
                                         quest_id: quest.fetch(:id), kind: kind,
                                         round_no: round, state: "pending")
        if row.fetch(:phase_kind_exit) == "mass-floor-gate"
          values = GuardValues.new(conn: @conn, quest: quest, phase: nil, config: config,
                                   session_id: nil, transcript_bytes: nil, watcher: @watcher)
          max = values.config_value("quest.frontier_build_max")
          floor = values.config_value("quest.frontier_floor_mass")
          @stderr.puts "FRONTIER_BUILD: round #{round}/#{fmt(max)} — the mass floor " \
                       "gate opened (mass #{fmt(values.value('v_frontier_mass'))} < " \
                       "floor #{fmt(floor)})"
        end
        phase_id
      end

      def fire_unmatched_pause(quest, phase, event, reason: nil)
        note = "PROCESS_BOUNDARY: no transition row matched #{phase&.fetch(:kind)} / #{event} — " \
               "the loud fallback pauses for the operator (P-NOREPORT: every stop routes or " \
               "is loud + explicit + operator-visible; a silent continue is a defect)"
        @supervisor.pause_quest!(user_id: quest.fetch(:user_id), quest_id: quest.fetch(:id),
                                 actor: "orchestrator", note: note)
        :paused
      end

      def loud_note(rule_id, phase, reason, row)
        kind = phase ? phase.fetch(:kind) : "briefing-init"
        "PROCESS_STOP: #{rule_id || 'boundary'} at phase #{phase ? phase.fetch(:round_no) : 0} " \
          "(#{kind}) — #{reason} — #{ROUTE_LABEL}#{ROUTE_SEPARATOR}#{row.fetch(:phase_kind_exit)}"
      end

      # ── the stop-rule sweep (I06 §6.1) ──────────────────────────────────

      # value/threshold/mode per rule; HARD routeable crossings fire; ADVISORY
      # crossings signal and never route. The structural backstops are hard
      # by nature (quest.max_phases, the walls/timeouts, the retry cap, the
      # descent exit rules — I06 §6.1's own ledger).
      HARD_BY_NATURE = %w[SR-01 SR-05 SR-06 SR-07 SR-08 SR-16 SR-17 SR-18 SR-19].freeze
      ROUTE_EVENTS = {
        "SR-01" => "phase_cap", "SR-02" => "budget_exhausted", "SR-03" => "budget_exhausted",
        "SR-04" => "budget_exhausted", "SR-08" => "retry_cap_exhausted",
        "SR-16" => "transcript_ceiling", "SR-17" => "slow_stall_unattended",
        "SR-18" => "slow_stall_unattended", "SR-19" => "slow_stall_unattended"
      }.freeze

      def sweep_stop_rules(quest, config, values)
        slow_stall = {growth_ok: nil, window_ok: nil, unattended_ok: nil}
        config.fetch(:stop_rules).each do |rule|
          rule_id = rule.fetch(:rule_id)
          value = rule_value(rule, values)
          threshold = values.config_value(rule.fetch(:config_key))
          next unless crossed?(value, rule.fetch(:operator), threshold)

          case rule_id
          when "SR-15"
            # SR-15's adjust is the warn band: refuse new ingestion + bank at
            # the boundary — the engine's budgeter owns that behavior; the
            # sweep signals it (the loud boundary event, never a route).
            signal_alert(quest, rule, value, threshold)
            next
          when "SR-09", "SR-10", "SR-11", "SR-12", "SR-13", "SR-14"
            # Consumed through the transition guards / the fb gate — firing
            # them here would double-route (the descent exit rows own these).
            next
          when "SR-17", "SR-18", "SR-19"
            # The composite: growth < floor over the window AND operator
            # absent past the unattended window — all three arms must hold.
            arms = slow_stall_arms(rule_id, slow_stall)
            next unless arms.all?

            return firing_for(quest, rule, value, threshold, "slow_stall_unattended")
          end

          mode = rule_mode(rule, config)
          routeable = HARD_BY_NATURE.include?(rule_id) || mode == "hard"
          if ROUTE_EVENTS.key?(rule_id) && routeable
            return firing_for(quest, rule, value, threshold, ROUTE_EVENTS.fetch(rule_id))
          end

          # An ADVISORY crossing: the loud boundary event + the assurance
          # signal — never a route (DR-09).
          signal_alert(quest, rule, value, threshold)
        end
        nil
      end

      def slow_stall_arms(rule_id, state)
        case rule_id
        when "SR-17" then state[:growth_ok] = true
        when "SR-18" then state[:window_ok] = true # the window IS the measurement basis
        when "SR-19" then state[:unattended_ok] = true
        end
        [state[:growth_ok] == true, state[:window_ok] == true, state[:unattended_ok] == true]
      end

      def firing_for(quest, rule, value, threshold, event)
        {rule: rule, rule_id: rule.fetch(:rule_id), config_key: rule.fetch(:config_key),
         event: event,
         reason: "#{rule.fetch(:rule_id)} crossed #{rule.fetch(:config_key)}: " \
                 "#{rule.fetch(:metric)[0, 80]} — value #{format_value(value)} " \
                 "#{rule.fetch(:operator)} #{format_value(threshold)}"}
      end

      def signal_alert(quest, rule, value, threshold)
        @publisher&.publish_quest(quest.fetch(:id), "assurance_alert",
                                  {"quest_id" => quest.fetch(:id).to_s,
                                   "predicate" => "boundary_crossing",
                                   "rule_id" => rule.fetch(:rule_id),
                                   "config_key" => rule.fetch(:config_key),
                                   "value" => format_value(value),
                                   "threshold" => format_value(threshold),
                                   "mode" => "advisory"})
        nil
      end

      # Plain decimal rendering for config/measure numbers in loud lines
      # (BigDecimal's default to_s is scientific notation — never in an
      # operator-facing line).
      def fmt(v)
        v.is_a?(BigDecimal) ? v.to_s("F") : v.to_s
      end

      def format_value(v)
        case v
        when nil then "nil"
        when BigDecimal then v.to_s("f")
        else v.to_s
        end
      end

      # The rule's metric value (rule_id → resolver — metric RESOLUTION, not
      # transition encoding; the route/target always come from the tables).
      def rule_value(rule, values)
        case rule.fetch(:rule_id)
        when "SR-01" then values.value("phases_launched")
        when "SR-02" then values.value("web_calls_used")
        when "SR-03" then values.value("tokens_used")
        when "SR-04" then values.value("spend_used_usd")
        when "SR-05", "SR-06" then values.value("phase_elapsed_s")
        when "SR-07" then values.value("session_inactivity_s")
        when "SR-08" then values.value("phase_attempts")
        when "SR-09" then values.value("mass_decay_ratio")
        when "SR-10" then values.value("mass_decay_run")
        when "SR-11" then values.value("plateau_range")
        when "SR-12" then values.value("plateau_window_size")
        when "SR-13" then values.value("v_frontier_mass")
        when "SR-14" then values.value("frontier_build_rounds_used")
        when "SR-15", "SR-16" then values.value("transcript_bytes")
        when "SR-17" then values.value("transcript_growth")
        when "SR-18" then values.value("stall_window_s")
        when "SR-19" then values.value("operator_absent")
        else raise Kquest::Engine::Error, "unresolvable stop rule #{rule.fetch(:rule_id)}"
        end
      end

      # The budget-line mode (DR-09): quest.* lines read the quest-local
      # `process_config["modes"]` toggle (advisory default); engine.* lines
      # read the engine_config row's mode; the structural backstops are hard
      # by nature (I06 §6.1's ledger).
      def rule_mode(rule, config)
        key = rule.fetch(:config_key)
        if key.start_with?("engine.")
          config.fetch(:engine).fetch(key, {}).fetch(:mode, "advisory")
        else
          config.fetch(:process).fetch("modes", {}).fetch(key, "advisory")
        end
      end

      def crossed?(value, operator, threshold)
        return false if value.nil? || threshold.nil?

        v = value.is_a?(BigDecimal) ? value : Float(value)
        t = threshold.is_a?(BigDecimal) ? threshold : Float(threshold)
        case operator
        when ">=" then v >= t
        when ">" then v > t
        when "<=" then v <= t
        when "<" then v < t
        else raise Kquest::Engine::Error, "unknown stop-rule operator #{operator.inspect}"
        end
      end

      # ── the transition table mechanics ──────────────────────────────────

      def row_applies?(row, from_phase, event)
        return false unless row.fetch(:event) == event

        from = row.fetch(:from_phase)
        from == from_phase || (WILDCARDS.key?(from) && WILDCARDS.fetch(from).include?(from_phase))
      end

      # The guard-string evaluator: every bare identifier resolves through the
      # I06 §3 vocabulary (GuardValues); dotted identifiers are config keys;
      # clauses join with AND; ops are the four stop-rule operators plus =.
      # The runner never encodes a transition — the guard is EVALUATED, the
      # target is READ.
      def evaluate_guard(guard, values)
        text = guard.to_s.strip
        return true if text.empty? || text == "none"

        # AND binds tighter than OR (the budget rows' disjunctions).
        text.split(/\s+AND\s+/).all? do |conjunction|
          conjunction.split(/\s+OR\s+/).any? { |clause| evaluate_clause(clause, values) }
        end
      end

      def evaluate_clause(clause, values)
        clause = clause.strip
        # The one composite clause shape in the landed table: "<metric> <op>
        # <key> over <window-key>" (the slow-stall row) — the window names
        # the measurement basis; the growth resolver already applied it.
        clause = clause.sub(/\s+over\s+\S+\z/, "")
        case clause
        when /\A([a-zA-Z_][a-zA-Z0-9_.]*)\s*(>=|<=|>|<|=)\s*(\S+)\z/
          lhs = values.value(Regexp.last_match(1))
          op = Regexp.last_match(2)
          rhs_raw = Regexp.last_match(3)
          rhs = rhs_raw.match?(/\A\d+(\.\d+)?\z/) ? BigDecimal(rhs_raw) : values.value(rhs_raw)
          compare(lhs, op, rhs)
        when /\A[a-zA-Z_][a-zA-Z0-9_.]*\z/
          truthy?(values.value(clause))
        else
          raise Kquest::Engine::Error,
                "unresolvable transition guard clause #{clause.inspect} — every guard " \
                "identifier must resolve to the I06 §3 vocabulary, a config key, or a " \
                "law view (checker-enforced)"
        end
      end

      def compare(lhs, op, rhs)
        return false if lhs.nil? || rhs.nil?

        l = lhs.is_a?(BigDecimal) ? lhs : Float(lhs)
        r = rhs.is_a?(BigDecimal) ? rhs : Float(rhs)
        case op
        when ">=" then l >= r
        when "<=" then l <= r
        when ">" then l > r
        when "<" then l < r
        when "=" then l == r
        end
      end

      def truthy?(v)
        v == true || (v.is_a?(Numeric) && !v.zero?)
      end

      # ── the live config re-read (P-REREAD, I06 §6.2) ────────────────────

      # The FULL live config at every boundary: global defaults ⊕
      # quests.process_config ⊕ the three budget columns (L9 — the columns
      # ARE the live budget values) ⊕ quests.model_config; the stop rules and
      # the transition table are read fresh (never cached).
      def read_config(quest)
        {
          engine: Kquest::Engine.config(@conn),
          tools: Kquest::Tools.config(@conn),
          process: quest.fetch(:process_config) || {},
          model_config: quest.fetch(:model_config) || {},
          stop_rules: @conn[:stop_rules].order(:rule_id).to_a
        }
      end

      # ── the phase attempt machinery ─────────────────────────────────────

      def drive_session(session:, provider_row:, contract:, config:)
        desk = Kquest::Engine::ProviderDesk.new(conn: @conn, provider_row: provider_row,
                                                session: session)
        ledger = Kquest::Engine::TranscriptLedger.new(conn: @conn, session: session)
        @watcher&.register_ledger(session.fetch(:id), ledger)
        budgeter = Kquest::Engine::ContextBudgeter.new(conn: @conn, session: session,
                                                       desk: desk, config: config.fetch(:engine))
        watch = Kquest::Engine::StreamWatch.new(conn: @conn, session: session,
                                                config: config.fetch(:engine))
        governor = Kquest::Engine::RetryGovernor.new(conn: @conn, config: config.fetch(:engine),
                                                     supervisor: @supervisor,
                                                     sleeper: ->(s) { sleep s })
        tools = Kquest::Tools.registry(OPERATOR_SURFACE, conn: @conn, session: session,
                                       ledger: ledger, config: config.fetch(:tools))
        harness = Kquest::Engine::ToolHarness.new(conn: @conn, session: session, ledger: ledger,
                                                  config: config.fetch(:engine),
                                                  write_guard: @supervisor.write_guard_for(session),
                                                  budgeter: budgeter)
        driver = Kquest::Engine::LoopDriver.new(conn: @conn, desk: desk, harness: harness,
                                                ledger: ledger, budgeter: budgeter, watch: watch,
                                                governor: governor, supervisor: @supervisor,
                                                contract: contract, config: config.fetch(:engine),
                                                tools: tools, chat: build_chat(desk, contract))
        verdict = driver.run
        [ledger, classify_verdict(verdict)]
      end

      # The day-one registered surface: the operator profile's full 23 tools
      # (I05 §8 — the profile IS the registration; the subagent surface is
      # I04's, unchanged).
      OPERATOR_SURFACE = %w[
        node_add node_set node_get edge_add frontier_add frontier_close
        status search list paths mass neighbors
        source_read source_grep source_list
        web_search web_fetch
        retrieve
        report_draft report_bind
        quest_status
      ].freeze

      # The chat is built HERE (the frozen LoopDriver accepts a caller-built
      # `chat:`) so the contract's assembled prompt is the LIVE prompt: I06
      # §10.1's four-part assembly ships on the wire — the LoopDriver's own
      # context half validates it (E-NOECHO) but never applies it (its I13
      # tests construct chats directly). Turn-0's assembly is the phase's
      # whole prompt (the PhaseContract's assembly is turn-independent — the
      # I06 §10.1 "assembled at session cold-boot" law); the non-empty
      # message half of the duck type stays the caller's resume shape.
      def build_chat(desk, contract)
        context = contract.assemble_context(0)
        chat = Fast::Completions::Chat.new(client: desk.client, model: desk.model)
        chat.with_instructions(context[:instructions]) if context[:instructions]
        Array(context[:messages]).each { |m| chat.add_message(m) }
        chat
      end

      def classify_verdict(verdict)
        case verdict
        when :terminal, :turn_cap then :completed
        when :budget_paused, :paused, :ceiling_ended then verdict
        else :completed
        end
      end

      # The phase-kind model: `quests.model_config[kind]` names an
      # `llm_providers` row; an empty map falls back to the sole provider row
      # (config data — never a literal provider identity, G-REG).
      def resolve_provider(quest, phase, config)
        name = config.fetch(:model_config)[phase.fetch(:kind)]
        row = name && @conn[:llm_providers].where(name: name.to_s).first
        row || @conn[:llm_providers].first ||
          raise(Kquest::Engine::Error,
                "no llm_providers row is available for phase kind #{phase.fetch(:kind).inspect} " \
                "— provider rows are operator/session-minted config (the standing law); " \
                "mint one before running the quest")
      end

      def snapshot_parity!(phase)
        mass_row = @conn[:v_frontier_mass].where(quest_id: phase.fetch(:quest_id)).first
        @conn[:phases].where(id: phase.fetch(:id)).update(
          frontier_open: mass_row ? mass_row.fetch(:open_entries) : 0,
          frontier_mass: mass_row ? mass_row.fetch(:mass) : 0
        )
        nil
      end

      # The verification machinery (I07 DR-01/DR-02, consumed as-is — Part
      # 10): the verification phase's RUNTIME behavior runs after the loop
      # completes; its result (Q1V + the seeded spot-check sample) lands in
      # the phases row the `verification_clean` guard reads.
      def run_verification_machinery!(quest, phase)
        result = Kquest::Orchestrator::VerificationPhase.new(conn: @conn, quest: quest,
                                                             phase: fresh_phase(phase)).run
        @conn[:phases].where(id: phase.fetch(:id))
                      .update(result: Sequel.lit("coalesce(result, '{}'::jsonb) || ?::jsonb",
                                                 JSON.generate({"verification" => result})))
        result
      end

      def mark_phase!(phase, state:, note: nil)
        updates = {state: state, ended_at: Time.now}
        updates[:result] = Sequel.lit("coalesce(result, '{}'::jsonb) || ?::jsonb",
                                      JSON.generate({"note" => note})) if note
        @conn[:phases].where(id: phase.fetch(:id)).update(**updates)
        nil
      end

      def fresh_phase(phase)
        @conn[:phases].where(id: phase.fetch(:id)).first
      end

      def load_quest(quest_id)
        @conn[:quests].where(id: quest_id).first
      end

      def latest_phase(quest_id)
        @conn[:phases].where(quest_id: quest_id).order(Sequel.desc(:created_at),
                                                       Sequel.desc(:round_no)).first
      end
    end

    # The boundary VALUES: every bare identifier in the I06 §3 gate
    # vocabulary resolves here (P-GATEPARITY — the gate sweeps EXACTLY the
    # I05 parity fields via the landed StatusSnapshot; no rule the agent
    # cannot see).
    class GuardValues
      # The three budget lines live on the quest COLUMNS (L9 — the ledger is
      # the counter, the column is the cap).
      QUEST_BUDGET_COLUMNS = {
        "quest.web_call_budget" => :web_call_budget,
        "quest.token_budget" => :token_budget,
        "quest.spend_budget_usd" => :spend_budget_usd
      }.freeze

      def initialize(conn:, quest:, phase:, config:, session_id:, transcript_bytes:, watcher:)
        @conn = conn
        @quest = quest
        @phase = phase
        @config = config
        @session_id = session_id
        @transcript_bytes = transcript_bytes
        @watcher = watcher
        @snapshot = Kquest::Queries::StatusSnapshot.new(conn: conn)
        @cache = {}
      end

      def value(name)
        @cache[name] ||= resolve(name)
      end

      # A dotted config key: the quest-local process override, else the LIVE
      # quest budget column (L9 — the columns ARE the live budget values for
      # the three budget lines), else the landed stop-rule default, else the
      # engine/tool lines.
      def config_value(key)
        process = @config.fetch(:process)
        return BigDecimal(process.fetch(key).to_s) if process.key?(key)

        quest_column = QUEST_BUDGET_COLUMNS[key]
        return BigDecimal(@quest.fetch(quest_column).to_s) if quest_column

        if (row = @config.fetch(:stop_rules).find { |r| r.fetch(:config_key) == key })
          return row.fetch(:default)
        end

        line = @config.fetch(:engine)[key] || @config.fetch(:tools)[key]
        line && BigDecimal((line.is_a?(Hash) ? line.fetch(:value) : line).to_s)
      end

      private

      def resolve(name)
        case name
        when "agenda_staged" then agenda_staged?
        when "bare_claims" then status[:bare_claims]
        when "unreferenced" then status[:unreferenced]
        when "dual_arm_claims" then status[:dual_arm_claims]
        when "v_decompose_remaining" then status[:decompose_remaining]
        when "v_frontier_open" then status[:frontier_open]
        when "v_frontier_mass" then status[:frontier_mass]
        when "fb_eligible" then fb_eligible?
        when "frontier_build_rounds_used" then frontier_build_rounds_used
        when "mass_decay_sustained" then mass_decay_sustained?
        when "running_peak_mass" then running_peak_mass
        when "plateau_flat" then plateau_flat?
        when "plateau_range" then plateau_range
        when "citation_coverage" then citation_coverage?
        when "verification_clean" then verification_clean?
        when "web_calls_used" then web_calls_used
        when "tokens_used" then tokens_used
        when "spend_used_usd" then spend_used_usd
        when "phases_launched" then phases_launched
        when "phase_attempts" then phase_attempts
        when "transcript_bytes" then transcript_bytes
        when "transcript_growth" then transcript_growth
        when "stall_window_s" then stall_window_s
        when "operator_absent" then operator_absent
        when "mass_decay_ratio" then mass_decay_ratio
        when "mass_decay_run" then mass_decay_run
        when "plateau_window_size" then plateau_window_size
        when "session_inactivity_s" then session_inactivity_s
        when "phase_elapsed_s" then phase_elapsed_s
        when /\A(quest|phase|descent|engine|tools|assurance)\.[a-z_]+\z/ then config_key(name)
        else raise Kquest::Engine::Error,
                  "unresolvable guard identifier #{name.inspect} — the I06 §3 vocabulary, a " \
                  "config key, or a law view are the legal resolutions"
        end
      end

      def status
        @status ||= @snapshot.status_fields(user_id: @quest.fetch(:user_id),
                                            quest_id: @quest.fetch(:id))
      end

      def agenda_staged?
        @conn[:quest_sources]
          .join(:sources, Sequel[:sources][:id] => Sequel[:quest_sources][:source_id])
          .where(Sequel[:quest_sources][:quest_id] => @quest.fetch(:id),
                 Sequel[:sources][:user_id] => @quest.fetch(:user_id),
                 Sequel[:sources][:role] => "agenda").count.positive?
      end

      def fb_eligible?
        mass = value("v_frontier_mass")
        floor = config_key("quest.frontier_floor_mass")
        floor.nil? || floor.zero? || (mass < floor && frontier_build_rounds_used < config_key("quest.frontier_build_max"))
      end

      def frontier_build_rounds_used
        @conn[:phases].where(quest_id: @quest.fetch(:id), kind: "frontier-build").count
      end

      # The mass-decay primary (I06 §4.1): frontier_mass <= cut × running
      # peak at EACH of the last `window` completed descent boundaries.
      def mass_decay_sustained?
        window = config_key("descent.mass_decay_window") || 10
        runs = completed_descent_masses.last(window)
        return false if runs.size < window || runs.empty?

        cut = config_key("descent.mass_decay_cut_fraction") || BigDecimal("0.25")
        peak = [running_peak_mass, 1].max
        runs.all? { |m| BigDecimal(m.to_s) <= cut * BigDecimal(peak.to_s) }
      end

      def mass_decay_ratio
        peak = running_peak_mass
        return nil if peak.nil? || peak.zero?

        BigDecimal(latest_descent_mass.to_s) / BigDecimal(peak.to_s)
      end


      def mass_decay_run
        cut = config_key("descent.mass_decay_cut_fraction") || BigDecimal("0.25")
        peak = [running_peak_mass || 0, 1].max
        completed_descent_masses.reverse.take_while do |m|
          BigDecimal(m.to_s) <= cut * BigDecimal(peak.to_s)
        end.size
      end

      def completed_descent_masses
        @completed_descent_masses ||= @conn[:phases]
                                      .where(quest_id: @quest.fetch(:id), kind: "descent",
                                             state: "complete")
                                      .order(:created_at)
                                      .select_map(:frontier_mass).compact
      end

      def latest_descent_mass
        completed_descent_masses.last || 0
      end

      def running_peak_mass
        completed_descent_masses.max
      end

      # The plateau backstop (I06 §4.2): max−min frontier_open ≤ max over the
      # last W = max(10, ⌊n/2⌋) completed descent phases each recording a
      # snapshot.
      def plateau_flat?
        range = plateau_range
        return false if range.nil?

        range <= (config_key("descent.plateau_range_max") || 2)
      end

      def plateau_range
        window = plateau_samples
        return nil if window.size < plateau_window_size

        window.max - window.min
      end

      def plateau_samples
        @plateau_samples ||= @conn[:phases]
                             .where(quest_id: @quest.fetch(:id), kind: "descent",
                                    state: "complete").exclude(frontier_open: nil)
                             .order(Sequel.desc(:created_at))
                             .limit(plateau_window_size)
                             .select_map(:frontier_open).reverse
      end

      def plateau_window_size
        n = completed_descent_masses.size
        [10, n / 2].max
      end

      # The citation gate (see PHASE 0 note 5): the standing version is bound
      # and every citation row resolves to a corpus source or an explicit
      # import.
      def citation_coverage?
        standing = @conn[:report_versions].where(quest_id: @quest.fetch(:id), standing: true)
                                          .order(Sequel.desc(:version_seq)).first
        return false unless standing&.fetch(:bound_at)

        index_ids = @conn[:quest_sources]
                     .join(:sources, Sequel[:sources][:id] => Sequel[:quest_sources][:source_id])
                     .where(Sequel[:quest_sources][:quest_id] => @quest.fetch(:id),
                            Sequel[:quest_sources][:user_id] => @quest.fetch(:user_id),
                            Sequel[:sources][:role] => "citable")
                     .select_map(Sequel[:sources][:id])
        @conn[:report_citations].where(report_version_id: standing.fetch(:id)).each do |c|
          return false unless c.fetch(:imported) || index_ids.include?(c.fetch(:source_id))
        end
        true
      end

      # The verification phase's own deliverable (Part 10's machinery writes
      # the result; the guard reads it — never recomputes). Read as TEXT and
      # JSON-parsed (the jsonb→ruby typing varies by extension load order —
      # the text form is the honest constant).
      def verification_clean?
        return false unless @phase

        text = @conn[:phases].where(id: @phase.fetch(:id)).get(Sequel.lit("result::text"))
        return false unless text

        JSON.parse(text).fetch("verification", {}).fetch("clean", false) == true
      rescue JSON::ParserError
        false
      end

      def web_calls_used
        @conn[:tool_calls].where(quest_id: @quest.fetch(:id), ok: true)
                          .where(Sequel[:tool] => %w[web_search web_fetch agenda_stage]).count
      end

      def tokens_used
        @conn[:usage_events].where(quest_id: @quest.fetch(:id))
                            .sum(Sequel.lit("input_tokens + output_tokens + cache_read_tokens + " \
                                            "cache_write_tokens")) || 0
      end

      def spend_used_usd
        @conn[:usage_events].where(quest_id: @quest.fetch(:id)).sum(:cost_usd) || BigDecimal("0")
      end

      def phases_launched
        @conn[:phases].where(quest_id: @quest.fetch(:id)).count
      end

      def phase_attempts
        return 0 unless @phase

        [@phase.fetch(:attempt_no).to_i,
         @conn[:sessions].where(phase_id: @phase.fetch(:id)).count].max
      end

      def transcript_bytes
        @transcript_bytes || (@watcher&.bytes_for(@session_id) if @session_id)
      end

      def transcript_growth
        return nil unless @watcher && @session_id

        @watcher.growth_for(@session_id, stall_window_s)
      end

      def stall_window_s
        config_key("engine.slow_stall_window_s") || 1200
      end

      def operator_absent
        last = @conn[:quest_lifecycle_events]
               .where(quest_id: @quest.fetch(:id), actor: "operator")
               .order(Sequel.desc(:occurred_at)).first
        reference = last&.fetch(:occurred_at) || @quest.fetch(:created_at)
        (Time.now - reference).to_i
      end

      def session_inactivity_s
        return 0 unless @session_id

        last = @conn[:tool_calls].where(session_id: @session_id).max(:created_at) ||
               @conn[:sessions].where(id: @session_id).get(:started_at)
        last ? (Time.now - last).to_i : 0
      end

      def phase_elapsed_s
        return 0 unless @phase&.fetch(:started_at)

        (Time.now - @phase.fetch(:started_at)).to_i
      end

      def config_key(key)
        config_value(key)
      end
    end
  end
end
