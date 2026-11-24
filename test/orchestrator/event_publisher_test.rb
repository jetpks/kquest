# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/orchestrator/event_publisher"
require_relative "../../lib/kquest/orchestrator/ledger_projector"
require_relative "../../lib/kquest/engine/subagent_runner"

# The SSE producers (I08 §3): the publisher's envelope shape (EXACTLY two
# fields), the MAXLEN cap, the two stream keys; the ledger projector's
# catalog coverage (all TEN types flow, projection-only). Real local redis,
# test-prefixed keys + cleanup.
class EventPublisherTest < Minitest::Test
  def setup
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    @quest_id = @tenancy[:quest_id]
    @phase_id = conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "decompose")
    @prefix = OrchestratorFixtures.redis_prefix
    @redis = OrchestratorFixtures.redis_client
    @publisher = Kquest::Orchestrator::EventPublisher.new(redis: @redis, prefix: @prefix)
  end

  def teardown
    Sync { OrchestratorFixtures.cleanup_redis(@redis, @prefix) } if @redis
    @redis&.close
    OrchestratorFixtures.cleanup(conn, user_id: @user_id)
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def quest_key = "#{@prefix}:sse:quest:#{@quest_id}"

  def entries(key)
    Sync do
      (@redis.call("XRANGE", key, "-", "+") || [])
        .map { |_id, fields| fields.each_slice(2).to_h }
    end
  end

  def test_envelope_is_exactly_two_fields_on_the_quest_stream_key
    Sync { @publisher.publish_quest(@quest_id, "quest.state", {"a" => 1}) }
    list = entries(quest_key)
    assert_equal 1, list.size
    assert_equal %w[type data], list.first.keys, "the envelope is EXACTLY two fields"
    assert_equal "quest.state", list.first["type"]
    assert_equal JSON.parse(list.first["data"]), {"a" => 1}
  end

  def test_maxlen_caps_the_stream_approximately
    # MAXLEN ~ trims at radix-node boundaries, so the cap only bites past the
    # node size — the test writes enough entries for it to bite (the shipped
    # cap is 5000; the test uses 500 over 1200 entries).
    cap = 500
    slim = Kquest::Orchestrator::EventPublisher.new(redis: @redis, prefix: @prefix,
                                                    maxlen_entries: cap)
    Sync do
      1200.times { |i| slim.publish_quest(@quest_id, "quest.state", {"i" => i}) }
    end
    assert_operator entries(quest_key).size, :<=, cap + 50,
                    "XADD MAXLEN ~ trims the tail stream (the stream is a tail, PG is the truth)"
  end

  def test_user_stream_key_carries_cross_quest_events
    Sync { @publisher.publish_user(@user_id, "assurance_alert", {"predicate" => "tw_wedge"}) }
    list = entries("#{@prefix}:sse:user:#{@user_id}")
    assert_equal 1, list.size
    assert_equal "assurance_alert", list.first["type"]
  end

  # ── the ledger projector (all TEN catalog types flow) ─────────────────

  def projector(subagent_registry: nil)
    Kquest::Orchestrator::LedgerProjector.new(conn: conn, publisher: @publisher,
                                              subagent_registry: subagent_registry)
  end

  def types
    entries(quest_key).map { |e| e["type"] }
  end

  def test_projector_publishes_the_catalog_from_the_live_ledgers
    Sync do
      runner = Kquest::Engine::SubagentRunner.new(conn: conn, config: {})
      projector = projector(subagent_registry: runner.registry)
      # Seed each ledger the catalog reads.
      conn[:quest_lifecycle_events].insert(user_id: @user_id, quest_id: @quest_id,
                                           from_state: "active", to_state: "paused",
                                           actor: "orchestrator", occurred_at: Time.now,
                                           note: "projector fixture")
      started = Time.now
      conn[:phases].where(id: @phase_id).update(state: "complete", started_at: started,
                                                ended_at: started + 1,
                                                frontier_open: 4, frontier_mass: 30)
      session_id = conn[:sessions].insert(user_id: @user_id, quest_id: @quest_id,
                                          phase_id: @phase_id, mode: "autonomous",
                                          driver: "orchestrator", model: "test-model")
      conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id, session_id: session_id,
                               seq: 1, tool: "status", args: Sequel.lit("'{}'::jsonb"),
                               result: Sequel.lit("'{}'::jsonb"), ok: true)
      conn[:usage_events].insert(user_id: @user_id, quest_id: @quest_id, phase_id: @phase_id,
                                 session_id: session_id, kind: "llm", model: "test-model",
                                 input_tokens: 10, output_tokens: 5)

      projector.project(@quest_id)

      seen = types
      %w[quest.state phase.state session.state tool.event spend.tick frontier.mass].each do |t|
        assert_includes seen, t, "the catalog event flowed from its ledger"
      end
      # The parity fields ride the phase payload exactly (I08 §3.2).
      phase_event = entries(quest_key).find { |e| e["type"] == "phase.state" }
      data = JSON.parse(phase_event["data"])
      %w[bare_claims unreferenced dual_arm_claims decompose_remaining frontier_open
         frontier_mass attempt_no phase_state phase_kind].each do |field|
        assert data.key?(field), "the phase payload carries #{field} (the parity fields)"
      end
    end
  end

  def test_projector_is_projection_only_and_cursors_resume
    Sync do
      proj = projector
      conn[:quest_lifecycle_events].insert(user_id: @user_id, quest_id: @quest_id,
                                           from_state: "active", to_state: "paused",
                                           actor: "orchestrator", occurred_at: Time.now)
      assert_operator proj.project(@quest_id), :>=, 1,
                      "a fresh projector replays the ledger (the client dedupes by id)"
      assert_equal 0, proj.project(@quest_id), "the cursor advanced — no double publish"

      conn[:quest_lifecycle_events].insert(user_id: @user_id, quest_id: @quest_id,
                                           from_state: "paused", to_state: "active",
                                           actor: "orchestrator", occurred_at: Time.now + 1)
      assert_equal 1, proj.project(@quest_id), "new ledger rows flow"
    end
  end

  def test_subagent_run_registry_projects_run_state_changes
    Sync do
      runner = Kquest::Engine::SubagentRunner.new(conn: conn, config: {})
      run = Kquest::Engine::SubagentRunner::Run.new(
        "run-1", SecureRandom.uuid, "survey", [1..2], :running, nil, Time.now, nil
      )
      runner.registry["run-1"] = run
      projector(subagent_registry: runner.registry).project(@quest_id)
      assert_includes types, "subagent.run"
    end
  end

  def test_all_ten_catalog_event_types_are_represented_in_the_producers
    # The static coverage leg (the runtime legs above cover the projector's
    # six): quest.stop (runner), assurance_alert (poller/watcher),
    # watcher.bytes (watcher), subagent.run (projector).
    corpus = Dir.glob(File.expand_path("../../lib/kquest/orchestrator/**/*.rb", __dir__))
                .map { |f| File.read(f) }.join("\n")
    %w[quest.state quest.stop phase.state session.state tool.event spend.tick
       frontier.mass assurance_alert subagent.run watcher.bytes].each do |t|
      assert_includes corpus, t, "the catalog event type is represented in the producers"
    end
  end
end
