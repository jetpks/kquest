# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# POST /quests/:quest_id/console/resume — the steering resume (I17 Part 2 /
# AC5): EVERY override rides the ledgered paused → active transition — ONE
# for_update transaction, ONE quest_lifecycle_events row whose note records
# every changed key from→to + who/why; budgets are ONLY-RAISE ("a cap may
# only RAISE on resume", I06 §6.2); config merges are shallow jsonb merges;
# refusals 422 with NO row, NO state change, NO config change; a live
# operator session refuses 422 naming the holder; no spawn.
class QuestConsoleResumeTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    Kquest::Engine::SessionSupervisor.registry_clear
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(
      conn, state: "paused", web_call_budget: 16, token_budget: 1_000_000,
      spend_budget_usd: 1.0, process_config: {"keep" => 1}
    )
    sign_in_as_owner
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    Kquest::Engine::SessionSupervisor.registry_clear
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  Owner = Struct.new(:id, :github_uid, :username, :name, :email, :avatar_url, keyword_init: true)

  def sign_in_as_owner
    row = conn[:users].where(id: @tenancy[:user_id]).first
    sign_in(Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                      name: row[:name], email: row[:email], avatar_url: row[:avatar_url]))
  end

  def post_resume(params) = post("/quests/#{@tenancy[:quest_id]}/console/resume", params: params)

  def test_resume_with_a_raised_budget_is_the_ledgered_transition
    status, headers, = post_resume(web_call_budget: 32, note: "the wall needs headroom")
    assert_equal 302, status
    quest = conn[:quests].where(id: @tenancy[:quest_id]).first
    assert_equal "active", quest[:state]
    assert_equal 32, quest[:web_call_budget]
    row = conn[:quest_lifecycle_events].where(quest_id: @tenancy[:quest_id]).first
    refute_nil row, "ONE ledger row"
    assert_equal "paused", row[:from_state]
    assert_equal "active", row[:to_state]
    assert_equal "operator", row[:actor]
    assert_includes row[:note], "ui console resume door"
    assert_includes row[:note], "web_call_budget 16→32", "EVERY changed key from→to"
    assert_includes row[:note], "why: the wall needs headroom", "the who/why"
    assert_match %r{/quests/#{@tenancy[:quest_id]}}, headers["location"]
    # the frozen shape's NO-writes law: no session, no phase, no tool_calls
    assert_empty conn[:sessions].where(quest_id: @tenancy[:quest_id])
    assert_empty conn[:phases].where(quest_id: @tenancy[:quest_id])
    assert_empty conn[:tool_calls]
  end

  def test_process_config_and_model_config_merge_shallowly_and_are_recorded
    status, = post_resume(process_config: '{"modes":{"web_budget":"hard"}}',
                          model_config: '{"decompose":"planner-b"}',
                          note: "making the line hard is the operator's config decision")
    assert_equal 302, status
    quest = conn[:quests].where(id: @tenancy[:quest_id]).first
    process_config = JSON.parse(quest[:process_config].is_a?(String) ? quest[:process_config] : quest[:process_config].to_json)
    model_config = JSON.parse(quest[:model_config].is_a?(String) ? quest[:model_config] : quest[:model_config].to_json)
    assert_equal 1, process_config["keep"], "SHALLOW merge — the untouched keys survive"
    assert_equal "hard", process_config.dig("modes", "web_budget")
    assert_equal "planner-b", model_config["decompose"]
    row = conn[:quest_lifecycle_events].where(quest_id: @tenancy[:quest_id]).first
    assert_includes row[:note], "process_config.modes nil→", "the changed key from→to"
    assert_includes row[:note], "model_config.decompose"
  end

  def test_a_plain_resume_without_overrides_needs_no_note
    status, = post_resume({})
    assert_equal 302, status
    assert_equal "active", conn[:quests].where(id: @tenancy[:quest_id]).first[:state]
    row = conn[:quest_lifecycle_events].where(quest_id: @tenancy[:quest_id]).first
    assert_includes row[:note], "ui console resume door"
  end

  def test_budget_refuses_to_lower_or_hold_the_cap_only_raise_422_no_change
    [:lowered, :held].each do |shape|
      params = shape == :lowered ? {web_call_budget: 8} : {web_call_budget: 16}
      conn[:quests].where(id: @tenancy[:quest_id]).update(state: "paused")
      before = conn[:quest_lifecycle_events].count
      status, _, body = post_resume(params.merge(note: "why"))
      assert_equal 422, status, "#{shape}: the refusal"
      assert_match(/a cap may only RAISE on resume \(I06 §6\.2\)/, Array(body).join)
      assert_equal before, conn[:quest_lifecycle_events].count, "NO ledger row"
      assert_equal "paused", conn[:quests].where(id: @tenancy[:quest_id]).first[:state]
      assert_equal 16, conn[:quests].where(id: @tenancy[:quest_id]).first[:web_call_budget],
                   "NO config change"
    end
  end

  def test_an_override_requires_the_note
    before = conn[:quest_lifecycle_events].count
    status, _, body = post_resume(web_call_budget: 32)
    assert_equal 422, status
    assert_match(/a note is required/, Array(body).join)
    assert_equal before, conn[:quest_lifecycle_events].count
    assert_equal "paused", conn[:quests].where(id: @tenancy[:quest_id]).first[:state]
  end

  def test_a_non_phase_kind_model_config_key_refuses_teaching
    status, _, body = post_resume(model_config: '{"bogus":"m"}', note: "why")
    assert_equal 422, status
    assert_match(/model_config keys are phase kinds/, Array(body).join)
    assert_equal "paused", conn[:quests].where(id: @tenancy[:quest_id]).first[:state]
  end

  def test_a_malformed_json_object_refuses_teaching_with_no_change
    status, _, body = post_resume(process_config: "{nope", note: "why")
    assert_equal 422, status
    assert_match(/process_config must be a JSON object/, Array(body).join)
    assert_equal "paused", conn[:quests].where(id: @tenancy[:quest_id]).first[:state]
  end

  def test_a_non_paused_quest_refuses_422_with_no_row
    conn[:quests].where(id: @tenancy[:quest_id]).update(state: "stopped")
    before = conn[:quest_lifecycle_events].count
    status, _, body = post_resume({})
    assert_equal 422, status
    assert_match(/not paused/, Array(body).join)
    assert_equal before, conn[:quest_lifecycle_events].count
    assert_equal "stopped", conn[:quests].where(id: @tenancy[:quest_id]).first[:state]
  end

  def test_a_live_operator_session_holding_the_quest_refuses_naming_the_holder
    quest = conn[:quests].where(id: @tenancy[:quest_id]).first
    session = Kquest::Ui::OperatorWrite.open_session!(
      conn, user: {id: @tenancy[:user_id], username: "the-operator"}, quest: quest
    )
    before = conn[:quest_lifecycle_events].count
    status, _, body = post_resume({})
    assert_equal 422, status
    joined = Array(body).join
    assert_includes joined, "WRITE-GUARD", "the FROZEN refusal text, verbatim"
    assert_includes joined, session.fetch(:id).to_s, "naming the holder session"
    assert_includes joined, "operator", "naming the holder driver"
    assert_equal before, conn[:quest_lifecycle_events].count, "no ledger row behind the refusal"
  end

  def test_non_owner_is_404_before_any_mutation
    other = OrchestratorFixtures.mint_tenancy(conn, state: "paused", topic: "not yours")
    before = conn[:quest_lifecycle_events].count
    status, = post("/quests/#{other[:quest_id]}/console/resume", params: {})
    assert_equal 404, status, "the OWNER gate — existence never leaked"
    assert_equal before, conn[:quest_lifecycle_events].count
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_absent_quest_is_404
    status, = post("/quests/#{SecureRandom.uuid}/console/resume", params: {})
    assert_equal 404, status
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = post_resume({})
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_no_process_is_ever_spawned
    Process.stub(:spawn, ->(*_args) { flunk "the UI never spawns — the launcher owns worker boot" }) do
      post_resume(web_call_budget: 32, note: "why")
    end
  end
end
