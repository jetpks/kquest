# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# GET /quests/:quest_id — the quest view (I16 Part 1): the parity block
# (composed through the SHARED formatter), the capped lists, counters,
# read-only config, fingerprint, and the visibility gate on BOTH sides.
class QuestShowTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn, process_config: {"a" => 1},
                                                model_config: {"b" => 2})
    seed_listing_cap("quest", 50)
    sign_in_as_owner
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
    OrchestratorFixtures.cleanup(conn, user_id: @other_user_id) if @other_user_id
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

  def mint_session_with_phase(kind: "descent", round_no: 3, attempt_no: 1)
    phase_id = conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    kind: kind, round_no: round_no, attempt_no: attempt_no)
    PipelineFixtures.mint_session(conn, user_id: @tenancy[:user_id],
                                  quest_id: @tenancy[:quest_id], phase_id: phase_id)
  end

  def test_owner_renders_the_quests_show_page_object
    status, headers, body = inertia_get("/quests/#{@tenancy[:quest_id]}")
    assert_equal 200, status
    assert_equal "true", headers["x-inertia"]
    data = parse_json(body)
    assert_equal "Quests/Show", data["component"]
    assert_equal "/quests/#{@tenancy[:quest_id]}", data["url"]
  end

  def test_parity_block_composes_through_the_shared_formatter
    mint_session_with_phase
    conn[:tool_calls].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                             session_id: conn[:sessions].where(quest_id: @tenancy[:quest_id]).first[:id],
                             seq: 1, tool: "web_search", args: "{}", result: "{}", ok: true)
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}")
    line = parse_json(body)["props"]["parity_line"]
    assert_equal "quest_status: quest=active phase=descent(3/1) writer=session/" \
                 "#{conn[:sessions].where(quest_id: @tenancy[:quest_id]).first[:id].to_s[0, 4]} " \
                 "web_calls=1/16 tokens=0/1.0M spend_usd=0.00/1.00",
                 line,
                 "the composed line comes from Kquest::Tools::QuestStatus.line"
  end

  def test_no_session_degrades_phase_and_writer_to_dash
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}")
    line = parse_json(body)["props"]["parity_line"]
    assert_includes line, "phase=- writer=-"
    assert_includes line, "web_calls=0/16", "the budget lines never depend on a session"
  end

  def test_counters_fingerprint_and_read_only_config_render
    source = OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                              quest_id: @tenancy[:quest_id], snapshot: "text")
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}")
    props = parse_json(body)["props"]
    assert_equal 1, props["counters"]["unmined_citable"], "v_unmined_sources via v_decompose_remaining"
    assert_match(/\A[0-9a-f]{64}\z/, props["fingerprint"], "v_quest_graph_fingerprint")
    assert_equal({ "a" => 1 }, props["quest"]["process_config"])
    assert_equal({ "b" => 2 }, props["quest"]["model_config"])
    assert_equal "/quests/#{@tenancy[:quest_id]}/stream", props["stream_url"]
  ensure
    conn[:quest_sources].where(source_id: source[:id]).delete if source
    conn[:sources].where(id: source[:id]).delete if source
  end

  def test_listings_are_capped_with_showing_fields_and_telemetry
    seed_listing_cap("quest", 2)
    3.times do |i|
      conn[:quest_lifecycle_events].insert(
        user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
        from_state: "active", to_state: "paused", actor: "orchestrator",
        occurred_at: Time.now - ((3 - i) * 3600), note: "event #{i}"
      )
    end
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}")
    props = parse_json(body)["props"]
    assert_equal 2, props["lifecycle"]["rows"].size
    assert_equal 3, props["lifecycle"]["requested"]
    assert_equal 2, props["lifecycle"]["cap"], "the cap comes from ui.listing_cap.quest"
    assert_equal 3, props["lifecycle"]["existed"]
    telemetry = conn[:cap_records].where(user_id: @tenancy[:user_id], surface: "quest")
    assert telemetry.count >= 1, "one telemetry row per capped listing request"
    assert_equal @tenancy[:quest_id], telemetry.first[:quest_id]
  end

  def test_invisible_quest_is_404_existence_not_leaked
    @other_user_id = conn[:users].insert(handle: "gh-#{SecureRandom.hex(6)}",
                                         github_uid: SecureRandom.uuid,
                                         username: "u#{SecureRandom.hex(6)}",
                                         name: "Other", created_at: Time.now)
    other_quest = conn[:quests].insert(user_id: @other_user_id, topic: "not yours",
                                       web_call_budget: 1, token_budget: 1, spend_budget_usd: 1)
    status, headers, body = inertia_get("/quests/#{other_quest}")
    assert_equal 404, status
    assert_match "application/json", headers["content-type"]
    assert_equal({ "error" => "Not found" }, parse_json(body))
  ensure
    conn[:quests].where(id: other_quest).delete if other_quest
  end

  def test_absent_quest_is_404
    status, = inertia_get("/quests/#{SecureRandom.uuid}")
    assert_equal 404, status
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = get("/quests/#{@tenancy[:quest_id]}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end
end
