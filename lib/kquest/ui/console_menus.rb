# frozen_string_literal: true

module Kquest
  module Ui
    # The steering console's menu catalog as a PURE DERIVATION (I17 Part 0.2;
    # I08 §5.1's ten-row runtime-decision table, R-076/D5): the active menus
    # derive from DURABLE state only — the quest row (state + the three
    # budget columns + model_config), the latest orchestrator-actor lifecycle
    # note (the `PROCESS_STOP: <rule-id> …` tokens the phase runner's
    # loud_note writes), the latest phases row, the optional ?alert= param,
    # and the stop_rules config rows the caller fetched (the crossed rule's
    # row is the menu's ECHOED evidence — config is the only evidence source,
    # the calibrated-constants law: no hardcoded literal anywhere).
    #
    # Each menu is {id:, trigger:, options:, evidence:}. NO option is
    # pre-picked, defaulted, or timed out anywhere in the shape (I08 §5.2 —
    # the console PRESENTS, the operator picks, the doors record). While the
    # quest is `active` NO menu is returned (the console is the read-only
    # live view + the pause button). The budget-advisory row's own law: NO
    # menu fires for advisory lines (pinned by the named test — making a
    # line hard is an operator config decision at pause, never automatic).
    # Empty state (an operator-paused quest with no orchestrator note): the
    # generic set — the model-qualification routing menu + the doors the
    # page always renders — never a fabricated trigger (Grounds §6.7).
    module ConsoleMenus
      # The loud_note token shape (lib/kquest/orchestrator/phase_runner.rb):
      # "PROCESS_STOP: SR-16 at phase 2 (descent) — <reason> — route: <exit>".
      PROCESS_STOP_TOKEN = /PROCESS_STOP:\s*(SR-\d{2})/
      FINISHER_KINDS = %w[synthesis verification].freeze
      BUDGET_RULE_IDS = %w[SR-01 SR-02 SR-03 SR-04].freeze
      SLOW_STALL_RULE_IDS = %w[SR-17 SR-18 SR-19].freeze
      # The 13 tw_* predicates; the hub-divergence signal is NOT muteable —
      # it routes to adjudication in the SOURCE quest (I08 §5.1 row 9: the
      # hub is derived, holds no state).
      ADJUDICATION_ALERT = "tw_hub_divergence"

      module_function

      def derive(quest:, latest_note:, latest_phase:, alert_param:, stop_rules: [])
        state = quest.fetch(:state)
        return {state: state, menus: []} if state == "active"

        note = latest_note.to_s
        rule_ids = note.scan(PROCESS_STOP_TOKEN).flatten.uniq
        menus = []
        menus << transcript_ceiling(quest, note, rule_ids, stop_rules)
        menus << retry_cap(quest, note, rule_ids, stop_rules)
        menus << budget_or_briefing(quest, note, rule_ids, latest_phase, stop_rules)
        menus << slow_stall(quest, note, rule_ids, stop_rules)
        menus << verification_failed(quest, note)
        menus << stop_loud(quest, note)
        menus << adjudication(quest, alert_param)
        menus << model_qualification(quest)
        {state: state, menus: menus.compact}
      end

      # ── the frozen trigger table (I08 §5.1, one builder per row) ────────

      # transcript ceiling — SR-16 (the hard bytes wall; the warn band SR-15
      # banked at the boundary before this menu opens).
      def transcript_ceiling(quest, note, rule_ids, stop_rules)
        return unless rule_ids.include?("SR-16")

        {id: "transcript-ceiling",
         trigger: {rule_ids: ["SR-16"], note: note},
         options: [
           {id: "swap-at-the-wall", label: "swap at the wall — route the remainder per the routing map"},
           {id: "compact-and-continue", label: "compact-and-continue — cold-boot a successor session from a compacted transcript"},
           {id: "refuse-and-report", label: "refuse-and-report — leave the quest paused for disposition"}
         ],
         evidence: evidence_for(quest, "SR-16", stop_rules, note,
                                config_keys: %w[engine.transcript_ceiling_warn_bytes
                                                engine.transcript_ceiling_hard_bytes])}
      end

      # retry cap exhausted — SR-08 (the frozen catalogue's "resume as-is ·
      # raise phase.retry_cap (recorded) · re-route model · stop").
      def retry_cap(quest, note, rule_ids, stop_rules)
        return unless rule_ids.include?("SR-08")

        {id: "retry-cap",
         trigger: {rule_ids: ["SR-08"], note: note},
         options: [
           {id: "resume-as-is", label: "resume as-is — a fresh attempt on the same config"},
           {id: "raise-retry-cap", label: "raise phase.retry_cap — a config edit recorded with who/why (rides the resume door)"},
           {id: "re-route", label: "re-route the phase kind's model (rides the resume door's model_config merge)"},
           {id: "stop", label: "stop the quest (the stop door)"}
         ],
         evidence: evidence_for(quest, "SR-08", stop_rules, note, config_keys: %w[phase.retry_cap])}
      end

      # budget exhausted — SR-02/03/04 at a finisher phase (budget-finisher),
      # or SR-01/02/03/04 at briefing-init (no phases row yet —
      # briefing-caps). The advisory lines' own law is the ABSENCE of any
      # menu for them (I08 §5.1 row 4; pinned by the named test).
      def budget_or_briefing(quest, note, rule_ids, latest_phase, stop_rules)
        budget_hit = rule_ids.select { |r| BUDGET_RULE_IDS.include?(r) }
        return if budget_hit.empty?

        if latest_phase.nil?
          return {id: "briefing-caps",
                  trigger: {rule_ids: budget_hit, phase: nil, note: note},
                  options: [
                    {id: "raise-the-cap", label: "raise the cap the briefing needs before autonomy (rides the resume door, only-raise)"},
                    {id: "abandon", label: "abandon cleanly (the stop door)"}
                  ],
                  evidence: budget_evidence(quest, budget_hit, stop_rules, note, nil)}
        end

        {id: "budget-finisher",
         trigger: {rule_ids: budget_hit, phase: phase_label(latest_phase), note: note},
         options: [
           {id: "raise-the-crossed-line", label: "raise the crossed line (a recorded edit; rides the resume door, only-raise)"},
           {id: "pause-for-disposition", label: "pause here and dispose — a budget stop is never silently reportless"}
         ],
         evidence: budget_evidence(quest, budget_hit, stop_rules, note, latest_phase)}
      end

      # slow stall, unattended — SR-17/18/19; FM-18 carried VERBATIM: the
      # driver is NOT to be killed on growth alone.
      def slow_stall(quest, note, rule_ids, stop_rules)
        hits = rule_ids.select { |r| SLOW_STALL_RULE_IDS.include?(r) }
        return if hits.empty?

        {id: "slow-stall",
         trigger: {rule_ids: hits, note: note},
         options: [
           {id: "resume", label: "resume — the stall may be a slow local model (expected pace)"},
           {id: "re-route", label: "re-route (rides the resume door's model_config merge)"},
           {id: "swap", label: "swap model (rides the resume door's model_config merge)"},
           {id: "stop", label: "stop (the stop door)"}
         ],
         evidence: evidence_for(quest, hits.first, stop_rules, note,
                                config_keys: %w[engine.slow_stall_bytes engine.slow_stall_window_s
                                                engine.unattended_pause_s],
                                fm18: "the driver is NOT to be killed on growth alone")}
      end

      # verification failed — the rework-pause (the event or its ROUTE token
      # in the note); re-synthesis rides the steering resume/restart with the
      # I06 §7.3 routing recorded (no spawn-shaped action exists).
      def verification_failed(quest, note)
        return unless note.match?("verification_failed") || note.match?("route: rework-pause")

        {id: "verification-failed",
         trigger: {event: "verification_failed", note: note},
         options: [
           {id: "correct-in-place", label: "correct in place and resume (the resume door)"},
           {id: "re-synthesize", label: "re-synthesize — the resume/restart door with the I06 §7.3 builder/writer routing recorded"},
           {id: "leave-paused", label: "leave paused"}
         ],
         evidence: {note: note, pinned_vs_live: "the drift between the pinned fingerprint and the reworked graph is detected, never prevented"}}
      end

      # graph_invalid stop-loud — the ONE stop that cannot route to
      # synthesis; state `stopped` + the event/route token in the note.
      def stop_loud(quest, note)
        return unless quest.fetch(:state) == "stopped"
        return unless note.match?("graph_invalid") || note.match?("route: stop-loud")

        {id: "stop-loud",
         trigger: {event: "graph_invalid", state: quest.fetch(:state), note: note},
         options: [
           {id: "restart", label: "restart — the ledgered stopped → active pair (the repair precedent; the repair path is named in the note)"}
         ],
         evidence: {note: note, repair_path: "needs repair, not a restart — the failing gate's fields are the note's own words"}}
      end

      # divergence / conflict findings — the ?alert= pre-load pointer: the
      # courtroom workflow lives in the SOURCE quest's graph browser (the
      # hub is derived, holds no state). tw_hub_divergence routes here and
      # is never muteable.
      def adjudication(quest, alert_param)
        return if alert_param.nil? || alert_param.to_s.strip.empty?

        predicate = alert_param.to_s
        {id: "adjudication",
         trigger: {alert: predicate, hub_derived: predicate == ADJUDICATION_ALERT},
         options: [
           {id: "open-the-docket", label: "open the graph browser's courtroom docket — ledger a conflict, hypothesize, cross-examine"},
           {id: "cross-examine", label: "cross-examine in the source quest (the mute is NOT available to this signal)"}
         ],
         evidence: {alert: predicate,
                    browser_url: "/quests/#{quest.fetch(:id)}/graph",
                    muteable: predicate != ADJUDICATION_ALERT}}
      end

      # model qualification — ANY pause: the routing-map editor (the menu's
      # evidence echoes the quest's model_config + the budget columns; the
      # page cites the ladder_passes rows per model — reviewable, never a
      # blocker, I07 DR-06).
      def model_qualification(quest)
        {id: "model-qualification",
         trigger: {state: quest.fetch(:state), any_pause: true},
         options: [
           {id: "edit-routing-map", label: "edit the routing map — the resume/restart door's model_config merge, recorded who/why"},
           {id: "keep", label: "keep the current routing"}
         ],
         evidence: {model_config: quest.fetch(:model_config),
                    ladder: "the ladder_passes evidence rows render beside each model input (cited, never blocking)"},
         routing: true}
      end

      # ── the evidence echo (config is the only source — never literals) ──

      def evidence_for(quest, rule_id, stop_rules, note, config_keys:, fm18: nil)
        {stop_rule: crossed_rule(rule_id, stop_rules), config_keys: config_keys,
         budgets: budget_columns(quest), note: note, fm18: fm18}.compact
      end

      def budget_evidence(quest, rule_ids, stop_rules, note, latest_phase)
        {stop_rule: rule_ids.map { |r| crossed_rule(r, stop_rules) }.compact.first,
         config_keys: rule_ids.map { |r| crossed_rule(r, stop_rules) }
                              .compact.map { |row| row[:config_key] }.uniq,
         budgets: budget_columns(quest), phase: latest_phase && phase_label(latest_phase),
         note: note}.compact
      end

      # The crossed rule's row, echoed verbatim from the stop_rules config
      # the caller fetched (metric/default/operator/config_key — no literal
      # threshold is ever carried here).
      def crossed_rule(rule_id, stop_rules)
        row = (stop_rules || []).find { |r| r[:rule_id] == rule_id || r["rule_id"] == rule_id }
        return nil unless row

        hash = row.to_hash
        [:rule_id, :scope, :metric, :default, :operator, :action, :config_key].each_with_object({}) do |k, acc|
          acc[k] = hash[k] || hash[k.to_s]
        end
      end

      # The quest's own budget columns — the operator raises THESE through
      # the resume/restart doors (only-raise, I06 §6.2).
      def budget_columns(quest)
        {web_call_budget: quest.fetch(:web_call_budget), token_budget: quest.fetch(:token_budget),
         spend_budget_usd: quest.fetch(:spend_budget_usd).to_s("F")}
      end

      def phase_label(phase)
        "#{phase.fetch(:kind)}(#{phase.fetch(:round_no)}/#{phase.fetch(:attempt_no)})"
      end
    end
  end
end
