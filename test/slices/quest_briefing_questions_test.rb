# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# POST /quests/:quest_id/briefing/questions — the topic questions merge into
# the binding decompose phase's `result` jsonb (the I03 DR-14 carrier), in
# the SAME transaction as the optional topic freeze and the
# `briefing_questions` audit row (I17 Part 3); empty lists / blank entries
# refuse 422; this is the ONLY direct [:phases] write any UI action makes.
class QuestBriefingQuestionsTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    Kquest::Engine::SessionSupervisor.registry_clear
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    sign_in_as_owner
    @session_id = Kquest::Ui::OperatorWrite.open_session!(
      conn, user: {id: @tenancy[:user_id], username: "op"},
      quest: conn[:quests].where(id: @tenancy[:quest_id]).first
    ).fetch(:id)
    @phase_id = conn[:sessions].where(id: @session_id).first.fetch(:phase_id)
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

  def phase_result
    raw = conn[:phases].where(id: @phase_id).first[:result]
    JSON.parse(raw.is_a?(String) ? raw : raw.to_json)
  end

  def post_questions(overrides = {})
    post("/quests/#{@tenancy[:quest_id]}/briefing/questions", params: {
      questions: ["what is the scope?", "which corpora bind?"]
    }.merge(overrides))
  end

  def test_the_questions_merge_into_the_phases_result_carrier_with_the_audit
    status, = post_questions
    assert_equal 302, status
    result = phase_result
    assert_equal ["what is the scope?", "which corpora bind?"], result["topic_questions"],
                 "the I03 DR-14 carrier: phases.result[\"topic_questions\"]"
    audit = conn[:tool_calls].where(session_id: @session_id, tool: "briefing_questions").first
    refute_nil audit, "the carrier write is audited in the same transaction"
    assert_equal true, audit[:ok]
  end

  def test_an_optional_topic_freeze_is_recorded
    old_topic = conn[:quests].where(id: @tenancy[:quest_id]).first[:topic]
    status, = post_questions(topic: "the frozen topic")
    assert_equal 302, status
    assert_equal "the frozen topic", conn[:quests].where(id: @tenancy[:quest_id]).first[:topic]
    audit = conn[:tool_calls].where(session_id: @session_id, tool: "briefing_questions").first
    assert_includes JSON.parse(audit[:args].is_a?(String) ? audit[:args] : audit[:args].to_json)["topic"],
                    "#{old_topic}→the frozen topic",
                 "the recorded topic change (from→to)"
  end

  def test_a_second_write_merges_over_the_first
    post_questions
    post("/quests/#{@tenancy[:quest_id]}/briefing/questions",
         params: {questions: ["the refined question?"]})
    assert_equal ["the refined question?"], phase_result["topic_questions"],
                 "the questions are the recorded state (the merge replaces the carrier)"
  end

  def test_an_empty_list_refuses_422_with_no_write
    status, _, body = post("/quests/#{@tenancy[:quest_id]}/briefing/questions",
                           params: {questions: []})
    assert_equal 422, status
    assert_match(/non-empty strings/, Array(body).join)
    assert_nil conn[:phases].where(id: @phase_id).first[:result], "no partial write"
  end

  def test_a_blank_entry_refuses_422
    status, _, body = post_questions(questions: ["a real question", "   "])
    assert_equal 422, status
    assert_match(/non-empty strings/, Array(body).join)
    assert_nil conn[:phases].where(id: @phase_id).first[:result]
  end

  def test_staging_requires_the_open_briefing_session
    conn[:sessions].where(id: @session_id).update(ended_at: Time.now)
    Kquest::Engine::SessionSupervisor.registry_clear
    status, _, body = post_questions
    assert_equal 422, status
    assert_match(/no open briefing session/, Array(body).join)
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/briefing/questions",
                   params: {questions: ["q"]})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end
end
