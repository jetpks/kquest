# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/orchestrator/event_publisher"
require_relative "../../lib/kquest/orchestrator/ledger_projector"
require_relative "../../lib/kquest/engine/subagent_runner"

# The ledger projector's own census file (I15 Part 12, by-name law): ALL TEN
# catalog types flow, the projection is PROJECTION-ONLY (no ledger writes,
# no cursor loss), and the phase ledger's BOUNDARY AMENDMENT re-publishes —
# the runner's parity snapshot lands by UPDATE after the row's insert was
# already tailed, so the phase projection is a change projection (otherwise
# `frontier.mass` would never flow). Real local redis, test-prefixed keys.
class LedgerProjectorTest < Minitest::Test
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

  def types
    Sync do
      (@redis.call("XRANGE", quest_key, "-", "+") || [])
        .map { |_id, fields| fields.each_slice(2).to_h.fetch("type") }
    end
  end

  # The boundary AMENDS the phase row (the parity snapshot) — the phase
  # projection is a change projection, so the frontier.mass event flows.
  def test_boundary_amended_phase_row_republishes_frontier_mass
    Sync do
      projector = Kquest::Orchestrator::LedgerProjector.new(conn: conn, publisher: @publisher)
      projector.project(@quest_id) # the insert is tailed (no frontier fields yet)

      # The runner's boundary: snapshot_parity! UPDATES the row.
      conn[:phases].where(id: @phase_id).update(started_at: Time.now, state: "complete", frontier_open: 4, frontier_mass: 30)
      projector.project(@quest_id)

      assert_includes types, "frontier.mass",
                      "the boundary amendment flows (a change projection, not a cursor)"
    end
  end

  def test_unchanged_phase_tuple_does_not_republish
    Sync do
      projector = Kquest::Orchestrator::LedgerProjector.new(conn: conn, publisher: @publisher)
      assert_operator projector.project(@quest_id), :>=, 1, "the new row flows"
      assert_equal 0, projector.project(@quest_id),
                   "an unchanged tuple never republishes (projection-only, no double publish)"
    end
  end

  def test_the_phase_payload_carries_exactly_the_i08_field_list
    Sync do
      conn[:phases].where(id: @phase_id).update(started_at: Time.now, state: "complete", frontier_open: 2, frontier_mass: 6)
      Kquest::Orchestrator::LedgerProjector.new(conn: conn, publisher: @publisher)
                                            .project(@quest_id)
      payload = Sync do
        (@redis.call("XRANGE", quest_key, "-", "+") || [])
          .map { |_id, f| f.each_slice(2).to_h }
          .find { |e| e["type"] == "phase.state" }
      end
      data = JSON.parse(payload["data"])
      %w[quest_id phase_id phase_kind attempt_no phase_state bare_claims unreferenced
         dual_arm_claims decompose_remaining frontier_open frontier_mass].each do |field|
        assert data.key?(field), "the phase payload carries #{field} (I08 §3.2)"
      end
    end
  end

  def test_all_ten_catalog_types_flow_projection_only
    Sync do
      runner = Kquest::Engine::SubagentRunner.new(conn: conn, config: {})
      runner.registry["run-1"] = Kquest::Engine::SubagentRunner::Run.new(
        "run-1", SecureRandom.uuid, "survey", [1..2], :running, nil, Time.now, nil
      )
      # The projector's own ledgers:
      conn[:quest_lifecycle_events].insert(user_id: @user_id, quest_id: @quest_id,
                                           from_state: "active", to_state: "paused",
                                           actor: "orchestrator", occurred_at: Time.now)
      conn[:phases].where(id: @phase_id).update(started_at: Time.now, state: "complete", frontier_open: 4, frontier_mass: 30)
      session_id = conn[:sessions].insert(user_id: @user_id, quest_id: @quest_id,
                                          phase_id: @phase_id, mode: "autonomous",
                                          driver: "orchestrator", model: "test-model")
      conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id, session_id: session_id,
                               seq: 1, tool: "status", args: Sequel.lit("'{}'::jsonb"),
                               result: Sequel.lit("'{}'::jsonb"), ok: true)
      conn[:usage_events].insert(user_id: @user_id, quest_id: @quest_id, phase_id: @phase_id,
                                 session_id: session_id, kind: "llm", model: "test-model",
                                 input_tokens: 10, output_tokens: 5)
      # The direct-producer events (the runner/poller/watcher own these):
      @publisher.publish_quest(@quest_id, "quest.stop", {"rule_id" => "SR-02"})
      @publisher.publish_quest(@quest_id, "assurance_alert", {"predicate" => "tw_wedge"})
      @publisher.publish_quest(@quest_id, "watcher.bytes", {"transcript_bytes" => 12})

      Kquest::Orchestrator::LedgerProjector.new(conn: conn, publisher: @publisher,
                                                subagent_registry: runner.registry)
                                           .project(@quest_id)

      seen = types
      assert_equal @publisher.class.const_get(:EVENT_TYPES).sort, seen.uniq.sort,
                   "ALL TEN catalog types flowed through the producers"
      assert_equal 0, conn[:quest_lifecycle_events].where(quest_id: @quest_id)
                         .where(Sequel.lit("note = 'projection-write'")).count,
                   "the projector wrote nothing (projection-only)"
    end
  end
end
