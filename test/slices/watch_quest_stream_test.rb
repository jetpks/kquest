# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# The watch slice's quest stream (I08 §3): the GATES run BEFORE any SSE
# header (403 for anonymous, 404-shaped ordinary JSON for absent/invisible
# quests), the envelope is the adopted two-field frame, and the transport
# behaviors (backlog-then-live, Last-Event-ID resume, heartbeat) are the
# substrate's, exercised here against the REAL route + real local redis with
# test-prefixed keys + cleanup.
class WatchQuestStreamTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @redis = OrchestratorFixtures.redis_client
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    Sync do
      @redis&.call("DEL", stream_key, "kquest:sse:user:#{@tenancy[:user_id]}")
    rescue StandardError
      nil
    end
    @redis&.close
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
    OrchestratorFixtures.cleanup(conn, user_id: @other_user_id) if @other_user_id
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  # The CANONICAL stream key (the action's frozen shape) — cleanup deletes
  # the exact keys this test touches (the quest/user uuids are per-test).
  def stream_key = "kquest:sse:quest:#{@tenancy[:quest_id]}"

  def get_stream_for(path)
    env = Rack::MockRequest.env_for(path, "REQUEST_METHOD" => "GET")
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    app.call(env)
  end

  Owner = Struct.new(:id, :github_uid, :username, :name, :email, :avatar_url, keyword_init: true)

  # The tenancy's OWN user row (minted by the fixtures — never a second row).
  def sign_in_as_owner
    row = conn[:users].where(id: @tenancy[:user_id]).first
    user = Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                     name: row[:name], email: row[:email], avatar_url: row[:avatar_url])
    sign_in(user)
    user
  end

  def test_anonymous_request_is_403_json_before_any_sse_header
    status, headers, body = get_stream_for("/quests/#{@tenancy[:quest_id]}/stream")
    assert_equal 403, status
    assert_match "application/json", headers["content-type"]
    assert_equal JSON.parse(Array(body).join), {"error" => "Forbidden"}
  end

  def test_absent_quest_is_404_json
    sign_in_as_owner
    status, headers, body = get_stream_for("/quests/#{SecureRandom.uuid}/stream")
    assert_equal 404, status
    assert_match "application/json", headers["content-type"]
    assert_equal JSON.parse(Array(body).join), {"error" => "Not found"}
  end

  def test_invisible_quest_is_404_json_existence_not_leaked
    sign_in_as_owner
    @other_user_id = conn[:users].insert(handle: "gh-#{SecureRandom.hex(6)}",
                                         github_uid: SecureRandom.uuid,
                                         username: "u#{SecureRandom.hex(6)}",
                                         name: "Other", created_at: Time.now)
    other_quest = conn[:quests].insert(user_id: @other_user_id, topic: "not yours",
                                       web_call_budget: 1, token_budget: 1,
                                       spend_budget_usd: 1)
    status, headers, body = get_stream_for("/quests/#{other_quest}/stream")
    assert_equal 404, status, "an invisible quest is indistinguishable from an absent one"
    assert_equal JSON.parse(Array(body).join), {"error" => "Not found"}
  ensure
    conn[:quests].where(id: other_quest).delete if other_quest
  end

  def test_public_source_grant_makes_the_quest_visible
    sign_in_as_owner
    @other_user_id = conn[:users].insert(handle: "gh-#{SecureRandom.hex(6)}",
                                         github_uid: SecureRandom.uuid,
                                         username: "u#{SecureRandom.hex(6)}",
                                         name: "Other", created_at: Time.now)
    other_quest = conn[:quests].insert(user_id: @other_user_id, topic: "shared quest",
                                       web_call_budget: 1, token_budget: 1,
                                       spend_budget_usd: 1)
    source = OrchestratorFixtures.mint_source(conn, user_id: @other_user_id,
                                              quest_id: other_quest, snapshot: "public text")
    conn[:resource_grants].insert(source_id: source[:id], owner_user_id: @other_user_id,
                                  is_public: true)

    status, headers, = get_stream_for("/quests/#{other_quest}/stream")
    assert_equal 200, status, "a public grant on one of the quest's sources opens the stream"
    assert_equal "text/event-stream", headers["content-type"]
  ensure
    conn[:resource_grants].where(source_id: source[:id]).delete if source
    conn[:quest_sources].where(source_id: source[:id]).delete if source
    conn[:sources].where(id: source[:id]).delete if source
    conn[:quests].where(id: other_quest).delete if other_quest
  end

  def test_owner_streams_the_backlog_then_live_with_last_event_id_resume
    sign_in_as_owner
    Sync do
      first = @redis.call("XADD", stream_key, "*", "type", "quest.state", "data",
                          %({"type":"quest.state","to_state":"active"}))
      @redis.call("XADD", stream_key, "*", "type", "phase.state", "data",
                  %({"type":"phase.state"}))

      status, headers, body = get_stream("/quests/#{@tenancy[:quest_id]}/stream")
      assert_equal 200, status
      assert_equal "text/event-stream", headers["content-type"]

      task = Async do
        @redis.call("XADD", stream_key, "*", "type", "tool.event", "data", %({"tool":"status"}))
      end

      chunks = collect_sse_chunks(body, timeout: 5)
      task.wait

      text = chunks.join
      assert_includes text, "id: #{first}", "the backlog replay carries redis ids"
      assert_includes text, '"quest.state"', "the two-field envelope rides the frame"
      assert_includes text, '"tool":"status"', "the live tail delivers"
    end
  end

  def test_last_event_id_resume_is_exclusive
    sign_in_as_owner
    Sync do
      first = @redis.call("XADD", stream_key, "*", "type", "quest.state", "data",
                          %({"type":"quest.state"}))
      @redis.call("XADD", stream_key, "*", "type", "phase.state", "data", %({"type":"phase.state"}))

      env = Rack::MockRequest.env_for("/quests/#{@tenancy[:quest_id]}/stream",
                                      "REQUEST_METHOD" => "GET")
      env["HTTP_COOKIE"] = @session_cookie
      env["HTTP_LAST_EVENT_ID"] = first
      _, _, body = app.call(env)

      chunks = collect_sse_chunks(body, timeout: 3)
      text = chunks.join
      refute_includes text, '"quest.state"',
                      "the cursor is exclusive — earlier entries do not replay"
      assert_includes text, '"phase.state"', "post-cursor entries replay"
    end
  end

  def test_heartbeat_pings_between_events
    sign_in_as_owner
    fanout_class = Kquest::SSE::Fanout
    original = fanout_class::HEARTBEAT_SECONDS
    fanout_class.send(:remove_const, :HEARTBEAT_SECONDS)
    fanout_class.const_set(:HEARTBEAT_SECONDS, 0.1)
    _, _, body = get_stream("/quests/#{@tenancy[:quest_id]}/stream")
    chunks = collect_sse_chunks(body, timeout: 3)
    assert_includes chunks.join, ": ping", "the heartbeat idiom pings on idle"
  ensure
    fanout_class.send(:remove_const, :HEARTBEAT_SECONDS)
    fanout_class.const_set(:HEARTBEAT_SECONDS, original)
  end
end
