# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# GET /quests/:quest_id/costs — the cost view (I16 Part 8, LAST): the reused
# Metrics families (one rollup, no second validator), the capped usage-event
# ledger with the model/window filters, the budget echo, the visibility gate.
# REPORTING-ONLY (I07 DR-08) — nothing here throttles or blocks.
class QuestCostsIndexTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    seed_listing_cap("costs", 100)
    sign_in_as_owner
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  Owner = Struct.new(:id, :github_uid, :username, :name, :email, :avatar_url, keyword_init: true)

  def sign_in_as_owner
    row = conn[:users].where(id: @tenancy[:user_id]).first
    user = Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                     name: row[:name], email: row[:email], avatar_url: row[:avatar_url])
    sign_in(user)
    user
  end

  def seed_listing_cap(surface, cap)
    key = "ui.listing_cap.#{surface}"
    conn[:tool_config].where(key: key).delete
    conn[:tool_config].insert(key: key, num_value: cap, text_value: nil,
                              provenance: "test data (the seeds re-heal at the next prepare)")
  end

  def mint_usage(model: "test-model", phase_id: nil, tokens: 100, round_no: 1)
    phase_id ||= conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                      kind: "descent", round_no: round_no)
    session_id = PipelineFixtures.mint_session(conn, user_id: @tenancy[:user_id],
                                               quest_id: @tenancy[:quest_id], phase_id: phase_id)
    conn[:usage_events].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                               phase_id: phase_id, session_id: session_id, kind: "llm",
                               model: model, input_tokens: tokens, output_tokens: 0,
                               cost_usd: BigDecimal("0.25"))
    [phase_id, session_id]
  end

  def test_owner_renders_the_costs_index_page_object
    mint_usage
    status, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/costs")
    assert_equal 200, status
    data = parse_json(body)
    assert_equal "Costs/Index", data["component"]
    assert_equal "/quests/#{@tenancy[:quest_id]}/costs", data["url"]
  end

  def test_panels_are_the_reused_metrics_families_not_a_second_rollup
    mint_usage
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/costs")
    panels = parse_json(body)["props"]["panels"]
    names = panels.map { |f| f["name"] }
    %w[kquest_closure_economics_cost_per_class kquest_cost_per_claim kquest_cost_per_evidence
       kquest_metabolism kquest_empty_completion_rate kquest_spend].each do |expected|
      assert_includes names, expected, "the family is REUSED from Kquest::Orchestrator::Metrics"
    end
    spend = panels.find { |f| f["name"] == "kquest_spend" }
    assert spend["samples"].any? { |s| s["labels"]["kind"] == "cost_usd" && s["value"].to_f > 0 },
           "the reused family carries the ledger rollup"
  end

  def test_the_phase_filter_narrows_the_reused_families_samples_by_label
    phase_a, = mint_usage(model: "model-a")
    mint_usage(model: "model-b", round_no: 2)
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/costs", params: {phase: phase_a})
    spend = parse_json(body)["props"]["panels"].find { |f| f["name"] == "kquest_spend" }
    refute_empty spend["samples"]
    assert(spend["samples"].all? { |s| s["labels"]["phase_id"] == phase_a.to_s },
           "the phase filter narrows the samples by their phase_id label")
  end

  def test_the_ledger_is_capped_with_telemetry_and_model_filter
    seed_listing_cap("costs", 1)
    mint_usage(model: "model-a")
    mint_usage(model: "model-b", round_no: 2)
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/costs", params: {model: "model-b"})
    ledger = parse_json(body)["props"]["ledger"]
    assert_equal 1, ledger["rows"].size
    assert_equal "model-b", ledger["rows"].first["model"]
    assert_equal 1, ledger["requested"]
    assert_equal 1, ledger["cap"]
    telemetry = conn[:cap_records].where(user_id: @tenancy[:user_id], surface: "costs")
    assert telemetry.count >= 1
    assert_equal @tenancy[:quest_id], telemetry.first[:quest_id]
  end

  def test_budgets_are_echoed_from_the_quest_row
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/costs")
    budgets = parse_json(body)["props"]["budgets"]
    assert_equal 16, budgets["web_call_budget"]
    assert_equal 1_000_000, budgets["token_budget"]
    assert_equal "1.0", budgets["spend_budget_usd"]
    assert_equal "/quests/#{@tenancy[:quest_id]}/stream", parse_json(body)["props"]["stream_url"]
  end

  def test_invisible_quest_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = inertia_get("/quests/#{other[:quest_id]}/costs")
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end
end
