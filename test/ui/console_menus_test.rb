# frozen_string_literal: true

require_relative "../test_helper"

# The menu catalog as a PURE DERIVATION (I17 Part 0.2 / I08 §5.1): triggers
# from durable state; the evidence ECHOES config (the crossed stop_rules row,
# the budget columns — never a hardcoded literal); NO menu while active; NO
# menu for the advisory budget lines (row 4's own law); NO option is
# pre-picked, defaulted, or timed out anywhere in the shape; the empty state
# renders the generic set without fabricating a trigger.
class ConsoleMenusTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def quest_row(state: "paused", phase_absent: false)
    {id: SecureRandom.uuid, state: state, web_call_budget: 16, token_budget: 1_000_000,
     spend_budget_usd: BigDecimal("1.0"),
     model_config: {"decompose" => "planner-x", "synthesis" => "writer-y"},
     phases_absent: phase_absent}
  end

  def stopped_rule(rule_id, config_key)
    {rule_id: rule_id, scope: "quest", metric: "the crossed metric",
     default: BigDecimal("450000"), operator: ">=",
     action: "pause-and-present", config_key: config_key}
  end

  def derive(quest:, note: nil, phase: nil, alert: nil, stop_rules: [])
    Kquest::Ui::ConsoleMenus.derive(quest: quest, latest_note: note, latest_phase: phase,
                                    alert_param: alert, stop_rules: stop_rules)
  end

  def menu_ids(result) = result[:menus].map { |m| m[:id] }

  def test_no_menu_while_active_the_console_is_the_live_view_plus_the_pause_button
    result = derive(quest: quest_row(state: "active"),
                    note: "PROCESS_STOP: SR-16 at phase 1 (decompose) — hard ceiling — route: pause-and-present")
    assert_equal "active", result[:state]
    assert_empty result[:menus], "I08 §5.2: while active NO menu is returned"
  end

  def test_transcript_ceiling_menu_from_the_sr16_note_token
    rule = stopped_rule("SR-16", "engine.transcript_ceiling_hard_bytes")
    result = derive(quest: quest_row,
                    note: "PROCESS_STOP: SR-16 at phase 2 (descent) — hard bytes — route: pause-and-present",
                    stop_rules: [rule])
    assert_includes menu_ids(result), "transcript-ceiling"
    menu = result[:menus].find { |m| m[:id] == "transcript-ceiling" }
    assert_equal ["swap-at-the-wall", "compact-and-continue", "refuse-and-report"],
                 menu[:options].map { |o| o[:id] }
    # the evidence ECHOES the crossed config row — never a hardcoded literal
    assert_equal rule, menu[:evidence][:stop_rule]
    assert_includes menu[:evidence][:config_keys], "engine.transcript_ceiling_hard_bytes"
    assert_equal 16, menu[:evidence][:budgets][:web_call_budget], "the budget columns echoed"
  end

  def test_retry_cap_menu_from_the_sr08_note_token
    rule = stopped_rule("SR-08", "phase.retry_cap")
    result = derive(quest: quest_row,
                    note: "PROCESS_STOP: SR-08 at phase 3 (descent) — retry cap — route: pause-and-present",
                    stop_rules: [rule])
    assert_includes menu_ids(result), "retry-cap"
    menu = result[:menus].find { |m| m[:id] == "retry-cap" }
    assert_equal rule[:config_key], menu[:evidence][:stop_rule][:config_key]
  end

  def test_budget_exhausted_at_a_finisher_phase_presents_budget_finisher
    rule = stopped_rule("SR-03", "spend_budget_usd")
    result = derive(quest: quest_row,
                    note: "PROCESS_STOP: SR-03 at phase 4 (synthesis) — spend — route: pause-and-present",
                    phase: {kind: "synthesis", round_no: 1, attempt_no: 1},
                    stop_rules: [rule])
    assert_includes menu_ids(result), "budget-finisher"
    menu = result[:menus].find { |m| m[:id] == "budget-finisher" }
    assert_equal "synthesis(1/1)", menu[:evidence][:phase]
    assert_equal rule, menu[:evidence][:stop_rule], "the crossed row is the evidence"
  end

  def test_budget_caps_at_briefing_init_no_phases_row_present_briefing_caps
    rule = stopped_rule("SR-02", "web_call_budget")
    result = derive(quest: quest_row,
                    note: "PROCESS_STOP: SR-02 at phase 0 (briefing-init) — web budget — route: pause-and-present",
                    stop_rules: [rule])
    assert_includes menu_ids(result), "briefing-caps"
    refute_includes menu_ids(result), "budget-finisher",
                    "no phases row — the briefing-init caps menu, not the finisher one"
  end

  def test_slow_stall_carries_the_fm18_rule_verbatim
    rule = stopped_rule("SR-18", "engine.slow_stall_window_s")
    result = derive(quest: quest_row,
                    note: "PROCESS_STOP: SR-18 at phase 2 (descent) — unattended — route: pause-and-present",
                    stop_rules: [rule])
    menu = result[:menus].find { |m| m[:id] == "slow-stall" }
    refute_nil menu, "SR-18 is a slow-stall trigger"
    assert_equal "the driver is NOT to be killed on growth alone",
                 menu[:evidence][:fm18], "FM-18 verbatim"
  end

  def test_verification_failed_menu_from_the_event_or_route_token
    result = derive(quest: quest_row,
                    note: "PROCESS_STOP: SR-11 at phase 5 (verification) — checks — route: rework-pause")
    assert_includes menu_ids(result), "verification-failed"
    menu = result[:menus].find { |m| m[:id] == "verification-failed" }
    assert(menu[:options].any? { |o| o[:id] == "re-synthesize" },
           "re-synthesis rides the steering doors (I06 §7.3) — no spawn-shaped option")
  end

  def test_stop_loud_menu_needs_stopped_state_and_the_graph_invalid_token
    result = derive(quest: quest_row(state: "stopped"),
                    note: "PROCESS_STOP: SR-06 at phase 1 (decompose) — graph invalid — route: stop-loud")
    assert_includes menu_ids(result), "stop-loud"
    # the same note on a merely paused quest does NOT fabricate the stop-loud menu
    paused = derive(quest: quest_row(state: "paused"),
                    note: "PROCESS_STOP: SR-06 at phase 1 (decompose) — graph invalid — route: stop-loud")
    refute_includes menu_ids(paused), "stop-loud",
                    "state stopped is part of the frozen trigger"
  end

  def test_adjudication_menu_from_the_alert_param_and_the_hub_signal_is_not_muteable
    result = derive(quest: quest_row, alert: "tw_slowstall")
    menu = result[:menus].find { |m| m[:id] == "adjudication" }
    refute_nil menu
    assert_equal true, menu[:evidence][:muteable]
    hub = derive(quest: quest_row, alert: "tw_hub_divergence")
    hub_menu = hub[:menus].find { |m| m[:id] == "adjudication" }
    assert_equal false, hub_menu[:evidence][:muteable],
                 "tw_hub_divergence is NOT muteable — it routes to adjudication"
    assert_includes hub_menu[:evidence][:browser_url], "/graph"
  end

  def test_model_qualification_fires_on_any_pause_and_echoes_the_routing_map
    result = derive(quest: quest_row) # no note at all — the EMPTY STATE
    assert_equal ["model-qualification"], menu_ids(result),
                 "the generic set is the routing editor (the doors the page renders are not menus)"
    menu = result[:menus].first
    assert_equal({"decompose" => "planner-x", "synthesis" => "writer-y"},
                 menu[:evidence][:model_config], "the evidence echoes config")
  end

  def test_the_empty_state_fabricates_no_trigger
    result = derive(quest: quest_row, note: nil, phase: nil)
    assert_equal ["model-qualification"], menu_ids(result),
                 "no trigger-specific menu without a durable trigger (Grounds §6.7)"
  end

  def test_no_menu_fires_for_the_advisory_budget_lines
    # Advisory lines never pause: a note WITHOUT a PROCESS_STOP token (the
    # advisory signal's shape) derives no budget menu of any id.
    result = derive(quest: quest_row,
                    note: "advisory: web_calls=15/16 — the operator may pause on their own judgment",
                    phase: {kind: "descent", round_no: 1, attempt_no: 2})
    refute_includes menu_ids(result), "budget-advisory"
    refute_includes menu_ids(result), "budget-finisher"
    assert_equal ["model-qualification"], menu_ids(result)
  end

  def test_no_option_is_pre_picked_defaulted_or_timed_out_anywhere_in_the_shape
    rules = %w[SR-16 SR-08 SR-03 SR-18].map do |r|
      stopped_rule(r, "engine.#{r.downcase.tr('-', '_')}")
    end
    result = derive(quest: quest_row,
                    note: "PROCESS_STOP: SR-16 at phase 1 (decompose) — x — route: pause-and-present",
                    phase: {kind: "synthesis", round_no: 1, attempt_no: 1},
                    alert: "tw_churn", stop_rules: rules)
    result[:menus].each do |menu|
      menu[:options].each do |option|
        assert_equal %i[id label], option.keys,
                     "#{menu[:id]}: an option is a presented choice — no default/pick/timeout flag"
      end
    end
  end

  def test_the_evidence_never_carries_a_hardcoded_calibrated_constant
    # No crossed row passed → the echo is nil, never a fabricated number.
    result = derive(quest: quest_row,
                    note: "PROCESS_STOP: SR-16 at phase 1 (decompose) — hard bytes — route: pause-and-present")
    menu = result[:menus].find { |m| m[:id] == "transcript-ceiling" }
    assert_nil menu[:evidence][:stop_rule],
               "config is the only evidence source — no literal is invented in its absence"
  end
end
