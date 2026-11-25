# frozen_string_literal: true

require_relative "../test_helper"
require "async/redis"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/orchestrator/worker_registry"

# The redis-backed worker liveness registry (I08 §2.3, DR-04): the TTL
# semantics (heartbeat 10 s, key TTL 30 s = 3×), the session attribution
# (the value's session_ids — the redis analogue of the landed in-process
# Set), and the dead-worker disappearance (the key expires with the worker —
# no reaper can leak a liveness key). Real local redis, test-prefixed keys +
# cleanup.
class WorkerRegistryTest < Minitest::Test
  def setup
    @prefix = OrchestratorFixtures.redis_prefix
    @redis = OrchestratorFixtures.redis_client
  end

  def teardown
    Sync { OrchestratorFixtures.cleanup_redis(@redis, @prefix) } if @redis
    @redis&.close
  end

  def registry(kind: "quest", quest_id: nil, ttl_s: Kquest::Orchestrator::WorkerRegistry::TTL_S)
    Kquest::Orchestrator::WorkerRegistry.new(redis: @redis, kind: kind, quest_id: quest_id,
                                             prefix: @prefix, ttl_s: ttl_s)
  end

  def test_register_writes_the_dr04_key_shape_with_ttl
    r = registry(quest_id: SecureRandom.uuid)
    r.register!
    raw = @redis.call("GET", r.key)
    assert raw, "the heartbeat key exists after register!"
    value = JSON.parse(raw)
    assert_equal "quest", value["kind"]
    assert_equal Process.pid, value["pid"]
    assert_equal r.quest_id.to_s, value["quest_id"]
    assert_equal [], value["session_ids"]
    ttl = @redis.call("TTL", r.key)
    assert_operator ttl, :<=, Kquest::Orchestrator::WorkerRegistry::TTL_S, "the key TTL is 3× the heartbeat"
    assert_operator ttl, :>, 0
  end

  def test_heartbeat_refreshes_ttl_and_session_ids
    r = registry(ttl_s: 30)
    r.register!
    @redis.call("DEL", r.key) # simulate a stale heartbeat window
    r.heartbeat!(session_ids: [1, 2])
    value = JSON.parse(@redis.call("GET", r.key))
    assert_equal %w[1 2], value["session_ids"]
    assert @redis.call("EXISTS", r.key), "the heartbeat rewrote the key"
  end

  def test_session_attribution_claim_and_release
    r = registry
    r.register!
    r.claim_session!("s-1")
    assert r.session_live?("s-1"), "a claimed session is live-held"
    r.release_session!("s-1")
    refute r.session_live?("s-1"), "a released session is unheld"
  end

  def test_dead_worker_disappearance_ends_its_sessions_liveness
    holder = registry
    holder.register!
    holder.claim_session!("s-orphan")
    assert holder.session_live?("s-orphan")

    # The worker dies: its key disappears (TTL expiry or orderly unregister —
    # DR-05 verbatim: the entry disappears WITH the worker).
    holder.unregister!
    refute holder.session_live?("s-orphan"),
           "a dead worker's sessions are unheld (the reaper's, not the gate's)"
  end

  def test_live_workers_lists_only_live_entries
    a = registry(kind: "quest")
    b = registry(kind: "job")
    a.register!
    b.register!
    uuids = registry.live_workers.map { |w| w[:worker_uuid] }
    assert_includes uuids, a.worker_uuid
    assert_includes uuids, b.worker_uuid
    b.unregister!
    refute_includes registry.live_workers.map { |w| w[:worker_uuid] }, b.worker_uuid
  end

  def test_session_live_is_class_level_across_registries
    holder = registry
    holder.register!
    holder.claim_session!("s-x")
    probe = registry
    assert probe.session_live?("s-x"), "any worker sees the holder's claim"
    refute probe.session_live?("s-never")
  end

  # F5 (I20 Part 3): the file's own source carries the explicit
  # `require "time"` (the named pin a hygiene finding gets). Ruby 4.0
  # resolves `Time#iso8601` in CORE — so this is explicit-dependency hygiene,
  # the discoverability law, not a live bug.
  def test_requires_time_explicitly
    source = File.read(File.expand_path("../../lib/kquest/orchestrator/worker_registry.rb", __dir__))
    assert_includes source, 'require "time"',
                    "the explicit require joins the file's own requires (json/securerandom/socket)"
  end
end
