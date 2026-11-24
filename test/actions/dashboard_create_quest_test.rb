# frozen_string_literal: true

require_relative "action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /quests — create quest (I16 Part 3): the ROW ONLY (state active,
# provenance fresh, the routing map into process_config/model_config); no
# session, no worker, no briefing (I17's). Invalid input → 422, no row.
class DashboardCreateQuestTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  Owner = Struct.new(:id, :github_uid, :username, :name, :email, :avatar_url, keyword_init: true)

  def sign_in_as_owner
    row = conn[:users].where(id: @tenancy[:user_id]).first
    sign_in(Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                      name: row[:name], email: row[:email], avatar_url: row[:avatar_url]))
  end

  def test_creates_the_row_only
    sign_in_as_owner
    status, headers, = post("/quests", params: {topic: "the created quest",
                                                web_call_budget: 16, token_budget: 1_000_000,
                                                spend_budget_usd: "1.50",
                                                model_config: '{"planner":"openrouter"}',
                                                process_config: '{"transcript_ceiling_bytes":450000}'})
    assert_equal 302, status
    quest = conn[:quests].where(topic: "the created quest").first
    refute_nil quest
    assert_equal "active", quest[:state]
    assert_equal "fresh", quest[:provenance_kind]
    assert_nil quest[:source_quest_id], "provenance fresh pairs with no source quest"
    assert_equal 16, quest[:web_call_budget]
    assert_equal BigDecimal("1.50"), quest[:spend_budget_usd]
    # jsonb round-trips as a Hash through the row (the sequels pg_json ext):
    # normalize through JSON for the assertion either way.
    assert_equal "openrouter", JSON.parse(quest[:model_config].is_a?(String) ? quest[:model_config] : quest[:model_config].to_json)["planner"]
    assert_equal 450000, JSON.parse(quest[:process_config].is_a?(String) ? quest[:process_config] : quest[:process_config].to_json)["transcript_ceiling_bytes"]
    assert_match %r{/quests/#{quest[:id]}}, headers["location"]
    # ROW ONLY: no session, no phase, no lifecycle event (the briefing is I17's).
    assert_empty conn[:sessions].where(quest_id: quest[:id])
    assert_empty conn[:phases].where(quest_id: quest[:id])
    assert_empty conn[:quest_lifecycle_events].where(quest_id: quest[:id])
  end

  def test_defaults_the_routing_maps_to_empty_objects
    sign_in_as_owner
    post("/quests", params: {topic: "bare quest", web_call_budget: 1, token_budget: 1,
                             spend_budget_usd: "0"})
    quest = conn[:quests].where(topic: "bare quest").first
    assert_equal({}, JSON.parse(quest[:model_config].to_json))
    assert_equal({}, JSON.parse(quest[:process_config].to_json))
  end

  def test_invalid_topic_is_422_with_no_row
    sign_in_as_owner
    before = conn[:quests].count
    status, _, body = post("/quests", params: {topic: "   ", web_call_budget: 1, token_budget: 1,
                                            spend_budget_usd: "0"})
    assert_equal 422, status
    assert_match "topic is required", Array(body).join, "the 422 body names the errors"
    assert_equal before, conn[:quests].count
  end

  def test_invalid_budget_or_config_is_422_with_no_row
    sign_in_as_owner
    before = conn[:quests].count
    status, _, body = post("/quests", params: {topic: "bad budgets", web_call_budget: "x",
                                            token_budget: 1, spend_budget_usd: "0",
                                            model_config: "{nope"})
    assert_equal 422, status
    errors = Array(body).join
    assert_includes errors, "web_call_budget"
    assert_includes errors, "model_config"
    assert_equal before, conn[:quests].count
  end

  def test_negative_budgets_are_422_never_a_db_check_500
    sign_in_as_owner
    before = conn[:quests].count
    status, _, body = post("/quests", params: {topic: "negative budgets",
                                               web_call_budget: -1, token_budget: -5,
                                               spend_budget_usd: "-2.50"})
    assert_equal 422, status, "I17 Part 8 (judge Finding 8): the teaching 422"
    errors = Array(body).join
    assert_includes errors, "web_call_budget must not be negative"
    assert_includes errors, "token_budget must not be negative"
    assert_includes errors, "spend_budget_usd must not be negative"
    assert_equal before, conn[:quests].count, "no row behind the refusal"
  end

  def test_anonymous_post_redirects_to_sign_in_without_creating
    before = conn[:quests].count
    status, = post("/quests", params: {topic: "nope", web_call_budget: 1, token_budget: 1,
                                       spend_budget_usd: "0"})
    assert_equal 302, status
    assert_equal before, conn[:quests].count
  end
end
