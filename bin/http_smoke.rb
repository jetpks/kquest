#!/usr/bin/env ruby
# frozen_string_literal: true

ENV["HANAMI_ENV"] ||= "test"

# In-process boot + route-resolve + SSE round-trip smoke.
# Usage: bundle exec ruby bin/http_smoke.rb
# Exit 0 = PASS; exit 1 = FAIL (error printed to stderr)
#
# The important invariant: no route returns 5xx. The SSE section round-trips
# the transport live: a smoke-local StreamAction subclass invoked directly as
# the rack endpoint it is — the transport's contract is that ANY subclass
# works (app/stream_action.rb's own header) — seeded via redis XADD, backlog
# + live-tail frames asserted.

require "hanami/boot"
require "rack/mock"
require "json"
require "async"
require "async/redis"
require "async/redis/endpoint"

INERTIA_GET_PATHS = %w[/].freeze

def smoke_call(verb, path)
  env = Rack::MockRequest.env_for(path, "REQUEST_METHOD" => verb)
  if verb == "GET" && INERTIA_GET_PATHS.include?(path)
    env["HTTP_X_INERTIA"] = "true"
    env["HTTP_X_INERTIA_VERSION"] = Kquest::App["vite"].digest
  end
  Kquest::App.call(env)
end

failures = []

# Routes that must NOT 5xx. The OmniAuth callback routes are exercised
# without tokens — failures are expected noise on stderr (OmniAuth logs the
# csrf ERROR by design and 302s to /auth/failure); the smoke asserts no 5xx.
ANON_ROUTES = [
  ["GET",    "/up"],
  ["GET",    "/auth/github/callback"],
  ["POST",   "/auth/github/callback"],
  ["GET",    "/auth/failure"],
  ["GET",    "/logout"],
  ["DELETE", "/logout"],
  ["GET",    "/"],
].freeze

ANON_ROUTES.each do |verb, path|
  begin
    status, _, _ = smoke_call(verb, path)
    if status >= 500
      failures << "#{verb} #{path} → #{status} (server error)"
    end
  rescue => e
    failures << "#{verb} #{path} → #{e.class}: #{e.message}"
  end
end

# GET / must return 200 (the shell's root landing page)
root_status, root_headers, root_body = smoke_call("GET", "/")
unless root_status == 200
  failures << "GET / → expected 200, got #{root_status}"
end

# GET /up must return 200
up_status, _, _ = smoke_call("GET", "/up")
unless up_status == 200
  failures << "GET /up → expected 200, got #{up_status}"
end

# --- SSE round-trip -----------------------------------------------------------------

SMOKE_STREAM_KEY = "sse:smoke"

# A smoke-local StreamAction: the transport serves any subclass, so the
# demo-free shell proves its live chain with this one, invoked directly as
# the rack endpoint it is (never routed).
class SmokeStream < Kquest::StreamAction
  def handle(req, res)
    render_stream(req, res, key: SMOKE_STREAM_KEY)
  end
end

# The transport rides redis: mirror the suite's own isolation law — REDIS_URL
# must be set and select a non-zero database (dev runs against db 0).
class MockStream
  def initialize(chunks)
    @chunks = chunks
  end

  def <<(data)
    @chunks << data
    self
  end

  def close(error = nil)
  end
end

Sync do
  url = ENV["REDIS_URL"]
  failures << "SSE round-trip → REDIS_URL must be set (the isolated test database)" unless url

  endpoint = url && Async::Redis::Endpoint.parse(url)
  if endpoint&.database.to_i.zero?
    failures << "SSE round-trip → REDIS_URL must select a database other than 0 " \
                "(got #{endpoint.database.inspect})"
  end

  redis_client = endpoint && Async::Redis::Client.new(endpoint)
  if redis_client
    begin
      redis_client.del(SMOKE_STREAM_KEY)
      redis_client.xadd(SMOKE_STREAM_KEY, "*", "type", "smoke",
        "data", %({"type":"smoke","n":1}))
      redis_client.xadd(SMOKE_STREAM_KEY, "*", "type", "smoke",
        "data", %({"type":"smoke","n":2}))

      status, headers, body = SmokeStream.new.call(
        Rack::MockRequest.env_for("/", "REQUEST_METHOD" => "GET")
      )
      unless status == 200
        failures << "SSE round-trip → expected 200, got #{status}"
      end
      unless headers["content-type"] == "text/event-stream"
        failures << "SSE round-trip → expected content-type text/event-stream, " \
                    "got #{headers['content-type'].inspect}"
      end
      unless headers["cache-control"] == "no-cache"
        failures << "SSE round-trip → expected cache-control no-cache, " \
                    "got #{headers['cache-control'].inspect}"
      end
      unless headers["x-accel-buffering"] == "no"
        failures << "SSE round-trip → expected x-accel-buffering no, " \
                    "got #{headers['x-accel-buffering'].inspect}"
      end

      chunks = []
      mock_stream = MockStream.new(chunks)
      body_task = Async do
        begin
          body.call(mock_stream)
        rescue
        end
      end

      # Sleep briefly to let XREAD BLOCK register in Redis before the live
      # XADD fires, then collect briefly and stop — the live tail has no
      # terminal event.
      sleep 0.05
      redis_client.xadd(SMOKE_STREAM_KEY, "*", "type", "smoke",
        "data", %({"type":"smoke","n":3}))
      sleep 0.3
      body_task.stop
      body_task.wait rescue nil

      payloads = chunks.join.scan(/^data: (.+)$/).map { |(data)| JSON.parse(data)["n"] }
      unless payloads == [1, 2, 3]
        failures << "SSE round-trip → expected payloads [1, 2, 3], got #{payloads.inspect}"
      end
      unless chunks.join.include?("id: ")
        failures << "SSE round-trip → frames carry no id: lines"
      end
    ensure
      redis_client.close
      Kquest::SSE::Fanout.stop(SMOKE_STREAM_KEY)
    end
  end
end

if failures.empty?
  puts "SMOKE OK — #{ANON_ROUTES.size} routes resolved, GET / → #{root_status}, " \
       "GET /up → #{up_status}, SSE round-trip: 2 backlog + 1 live frames"
  exit 0
else
  $stderr.puts "SMOKE FAIL:"
  failures.each { |f| $stderr.puts "  - #{f}" }
  exit 1
end
