# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# GET /alerts/stream — the USER-level SSE serving action (I16 Part 4): the
# I15 EventPublisher producer (`kquest:sse:user:<uuid>`) finally has its
# server. Gate FIRST (unauthenticated → 403 JSON BEFORE any SSE header); the
# adopted backlog-then-live transport with Last-Event-ID resume; the I15
# frozen URL contract is untouched.
class WatchUserStreamTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @redis = OrchestratorFixtures.redis_client
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    sign_in_as_owner
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    Sync do
      @redis&.call("DEL", stream_key)
    rescue StandardError
      nil
    end
    @redis&.close
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  # The canonical USER stream key (the action's frozen shape — the landed
  # EventPublisher's key, not the fixture namespace).
  def stream_key = "kquest:sse:user:#{@tenancy[:user_id]}"

  Owner = Struct.new(:id, :github_uid, :username, :name, :email, :avatar_url, keyword_init: true)

  def sign_in_as_owner
    row = conn[:users].where(id: @tenancy[:user_id]).first
    user = Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                     name: row[:name], email: row[:email], avatar_url: row[:avatar_url])
    sign_in(user)
    user
  end

  def test_anonymous_request_is_403_json_before_any_sse_header
    sign_out
    status, headers, body = get_stream("/alerts/stream")
    assert_equal 403, status
    assert_match "application/json", headers["content-type"]
    refute headers["content-type"]&.start_with?("text/event-stream"),
           "no SSE header before the gate — the error stays ordinary JSON"
    assert_equal JSON.parse(Array(body).join), {"error" => "Forbidden"}
  end

  def test_signed_in_streams_the_backlog_then_live
    Sync do
      @redis.call("XADD", stream_key, "*", "type", "quest.state", "data",
                  %({"type":"quest.state","to_state":"paused"}))
      @redis.call("XADD", stream_key, "*", "type", "spend.tick", "data",
                  %({"type":"spend.tick","spend_usd":"1.24"}))
    end
    status, headers, body = get_stream("/alerts/stream")
    assert_equal 200, status
    assert_equal "text/event-stream", headers["content-type"]
    chunks = collect_sse_chunks(body)
    joined = chunks.join
    assert_includes joined, "quest.state"
    assert_includes joined, "to_state\":\"paused"
    assert_includes joined, "spend.tick"
    assert_includes joined, "1.24"
  end

  def test_last_event_id_resumes_from_the_bound
    Sync do
      first = @redis.call("XADD", stream_key, "*", "type", "a", "data", %({"type":"a"}))
      @redis.call("XADD", stream_key, "*", "type", "b", "data", %({"type":"b"}))
      first
    end
    first_id = Sync { @redis.call("XRANGE", stream_key, "-", "+") }.first.first
    env = Rack::MockRequest.env_for("/alerts/stream", "REQUEST_METHOD" => "GET")
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    env["HTTP_LAST_EVENT_ID"] = first_id
    _, _, body = app.call(env)
    chunks = collect_sse_chunks(body)
    joined = chunks.join
    refute_includes joined, '"type":"a"', "the resumed stream starts AFTER the bound"
    assert_includes joined, '"type":"b"'
  end

  def test_the_key_is_the_publishers_user_stream
    # The producer side (I15 EventPublisher#publish_user) XADDs onto this key;
    # the server reads the SAME key — proven by publishing through the landed
    # producer and reading it back through the action.
    Sync do
      Kquest::Orchestrator::EventPublisher.new(redis: @redis)
        .publish_user(@tenancy[:user_id], "assurance_alert", {predicate: "tw_wedge"})
    end
    _, headers, body = get_stream("/alerts/stream")
    chunks = collect_sse_chunks(body)
    assert_includes chunks.join, "predicate",
                    "the producer's envelope reaches the server through the SAME key"
  end

end
