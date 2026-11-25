# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# GET /quests/:quest_id/briefing — the CHAT page (I18 the §8 amendment; was
# the I17 staging-forms briefing): the agenda list capped (surface
# `briefing`), the agenda_staged gate state (≥1 agenda source), the open
# session state, the binding decompose round-1 phase, the topic_questions
# carrier, the TRANSCRIPT replayed from the session ledger blob through the
# reader's stubbable sink seam (the I13 pattern — a pre-filled MemorySink
# proves blob → props), and the QUEUED still-enqueued turns. PH0-CU-2 is
# the queued scope law.
class QuestBriefingIndexTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    Kquest::Engine::SessionSupervisor.registry_clear
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    seed_listing_cap("briefing", 1)
    seed_listing_cap("briefing_transcript", 200)
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

  def open_briefing_session
    Kquest::Ui::OperatorWrite.open_session!(
      conn, user: {id: @tenancy[:user_id], username: "op"},
      quest: conn[:quests].where(id: @tenancy[:quest_id]).first
    )
  end

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
    assert_equal({"lines" => [], "omitted" => 0}, props["transcript"],
                 "no session — nothing to replay (the blob is session-keyed)")
    assert_empty props["queued"], "no session — nothing is servable"
    assert_equal "/quests/#{@tenancy[:quest_id]}/stream", props["stream_url"],
                 "the frozen stream URL"
  end

  def test_agenda_staged_and_the_binding_phase_and_the_carrier_after_staging
    session_id = open_briefing_session.fetch(:id)
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
    open_briefing_session
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

  def test_the_transcript_replays_from_the_ledger_blob_through_the_stubbable_sink
    session = open_briefing_session
    location = Kquest::BlobUploader.location_for(:transcript, session_id: session.fetch(:id))
    sink = Kquest::Engine::TranscriptLedger::MemorySink.new
    [{type: "operator", body: "scope the decay question"},
     {type: "text_delta", text: "scope"},
     {type: "tool_call_start", tool_call: {id: "ix1", name: "web_search",
                                           arguments: {query: "decay"}}},
     {type: "tool_result", tool: "web_search", args: {query: "decay"},
      content: "3 results", is_error: false},
     {type: "final", turn: 1, stop_reason: nil,
      message: {content: [{type: "text", text: "Staged the primer — refine anything?"}]}}]
      .each { |line| sink.append(location, "#{JSON.generate(line)}\n") }
    Kquest::Engine::TranscriptLedger.singleton_class.alias_method(:i18cu_original_build_sink,
                                                                  :build_sink)
    Kquest::Engine::TranscriptLedger.singleton_class.define_method(:build_sink) { sink }
    _, _, body = briefing_get
    transcript = parse_json(body)["props"]["transcript"]
    assert_equal [
      {"kind" => "operator", "body" => "scope the decay question"},
      {"kind" => "tool_call", "tool" => "web_search", "excerpt" => "{\"query\":\"decay\"}"},
      {"kind" => "tool_result", "tool" => "web_search", "excerpt" => "3 results",
       "is_error" => false},
      {"kind" => "final", "body" => "Staged the primer — refine anything?"}
    ], transcript["lines"],
                 "blob → props through the sink seam (deltas render nothing; the four frozen kinds)"
    assert_equal 0, transcript["omitted"]
  ensure
    Kquest::Engine::TranscriptLedger.singleton_class.alias_method(:build_sink,
                                                                  :i18cu_original_build_sink)
    Kquest::Engine::TranscriptLedger.singleton_class.remove_method(:i18cu_original_build_sink)
  end

  def test_the_transcript_tail_is_capped_with_the_honest_omitted_count
    session = open_briefing_session
    seed_listing_cap("briefing_transcript", 2)
    location = Kquest::BlobUploader.location_for(:transcript, session_id: session.fetch(:id))
    sink = Kquest::Engine::TranscriptLedger::MemorySink.new
    3.times do |i|
      sink.append(location, "#{JSON.generate({type: "operator", body: "turn #{i + 1}"})}\n")
    end
    Kquest::Engine::TranscriptLedger.singleton_class.alias_method(:i18cu_original_build_sink,
                                                                  :build_sink)
    Kquest::Engine::TranscriptLedger.singleton_class.define_method(:build_sink) { sink }
    _, _, body = briefing_get
    transcript = parse_json(body)["props"]["transcript"]
    assert_equal ["turn 2", "turn 3"], transcript["lines"].map { |l| l["body"] }
    assert_equal 1, transcript["omitted"], "the omitted count is honest (never silent)"
  ensure
    Kquest::Engine::TranscriptLedger.singleton_class.alias_method(:build_sink,
                                                                  :i18cu_original_build_sink)
    Kquest::Engine::TranscriptLedger.singleton_class.remove_method(:i18cu_original_build_sink)
  end

  def test_queued_carries_the_open_sessions_enqueued_turns_and_nothing_after_signoff
    session = open_briefing_session
    Kquest::Ui::OperatorWrite.enqueue_turn!(conn, session: session, body: "first question")
    Kquest::Ui::OperatorWrite.enqueue_turn!(conn, session: session, body: "second question")
    _, _, body = briefing_get
    queued = parse_json(body)["props"]["queued"]
    assert_equal [1, 2], queued.map { |t| t["seq"] }
    assert_equal ["first question", "second question"], queued.map { |t| t["body"] }
    assert queued.first["id"], "the row id rides the prop"

    Kquest::Ui::OperatorWrite.end_session!(conn, quest_id: @tenancy[:quest_id])
    _, _, body = briefing_get
    assert_empty parse_json(body)["props"]["queued"],
                 "no session — nothing is servable (the dead-lettered turns are skipped)"
    states = conn[:briefing_turns].order(:seq).select_map(:state)
    assert_equal %w[skipped skipped], states, "the sign-off dead-lettered the queue"
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
