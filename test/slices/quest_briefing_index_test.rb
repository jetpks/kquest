# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# GET /quests/:quest_id/briefing — the interactive briefing page (I17 Part 3
# / I06 §8): the agenda list capped (surface `briefing`), the
# agenda_staged gate state (the transition law's own predicate: ≥1 agenda
# source), the open session state, the binding decompose round-1 phase, and
# the current topic_questions (the I03 DR-14 carrier).
class QuestBriefingIndexTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    Kquest::Engine::SessionSupervisor.registry_clear
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    seed_listing_cap("briefing", 1)
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

  def seed_listing_cap(surface, cap)
    key = "ui.listing_cap.#{surface}"
    conn[:tool_config].where(key: key).delete
    conn[:tool_config].insert(key: key, num_value: cap, text_value: nil,
                              provenance: "test data (the seeds re-heal at the next prepare)")
  end

  def briefing_get = inertia_get("/quests/#{@tenancy[:quest_id]}/briefing")

  def test_owner_renders_the_briefing_page_object_day_one_empty
    status, _, body = briefing_get
    assert_equal 200, status
    props = parse_json(body)["props"]
    assert_equal "Quests/Briefing", parse_json(body)["component"]
    assert_equal @tenancy[:quest_id], props["quest"]["id"]
    assert_empty props["agenda"]["rows"]
    assert_equal false, props["agenda_staged"],
                 "the gate state renders honestly (≥1 agenda source)"
    assert_nil props["session"], "no open session day one"
    assert_nil props["binding_phase_id"], "no phases row yet — the mint is the session's act"
    assert_empty props["topic_questions"]
  end

  def test_agenda_staged_and_the_binding_phase_and_the_carrier_after_staging
    # the briefing session's own acts, minted the way the actions do them:
    session_id = Kquest::Ui::OperatorWrite.open_session!(
      conn, user: {id: @tenancy[:user_id], username: "op"},
      quest: conn[:quests].where(id: @tenancy[:quest_id]).first
    ).fetch(:id)
    phase_id = conn[:sessions].where(id: session_id).first.fetch(:phase_id)
    OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                     quest_id: @tenancy[:quest_id],
                                     snapshot: "agenda doc text", role: "agenda",
                                     title: "the agenda doc")
    conn[:phases].where(id: phase_id).update(
      result: Sequel.lit("?::jsonb", JSON.generate("topic_questions" => ["what is the scope?"]))
    )
    _, _, body = briefing_get
    props = parse_json(body)["props"]
    assert_equal true, props["agenda_staged"]
    assert_equal 1, props["agenda"]["rows"].size
    assert_equal "the agenda doc", props["agenda"]["rows"].first["title"]
    assert_equal phase_id, props["binding_phase_id"]
    assert_equal "decompose(1/1)", props["binding_phase"]
    assert_equal ["what is the scope?"], props["topic_questions"]
    assert_equal session_id, props["session"]["id"]
  end

  def test_the_agenda_list_is_capped_with_showing_fields
    session_id = Kquest::Ui::OperatorWrite.open_session!(
      conn, user: {id: @tenancy[:user_id], username: "op"},
      quest: conn[:quests].where(id: @tenancy[:quest_id]).first
    ).fetch(:id)
    _ = session_id
    2.times do |i|
      OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                       quest_id: @tenancy[:quest_id],
                                       snapshot: "doc #{i}", role: "agenda",
                                       title: "agenda doc #{i}")
    end
    _, _, body = briefing_get
    agenda = parse_json(body)["props"]["agenda"]
    assert_equal 1, agenda["rows"].size, "the surface cap is 1 (seeded in setup)"
    assert_equal 2, agenda["requested"]
    assert_equal 1, agenda["cap"]
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = inertia_get("/quests/#{other[:quest_id]}/briefing")
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = briefing_get
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end
end
