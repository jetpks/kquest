# frozen_string_literal: true

require "securerandom"
require "digest"
require_relative "pipeline_fixtures"

# The orchestrator suite's fixture mint (all keyless — the mock wires ARE the
# wires; local redis/postgres are infrastructure, never credentials). Follows
# the landed PipelineFixtures tenancy-mint pattern (read-only consumed): the
# quest-leg additions live here, the shared tenancy/model/job mints stay
# PipelineFixtures'.
#
#   OrchestratorFixtures.mint_quest(conn, ...)    → quest_id (budgets + process_config)
#   OrchestratorFixtures.mint_source(conn, ...)   → source (snapshot blob + quest membership)
#   OrchestratorFixtures.redis_client             → a test-local async-redis client
#   OrchestratorFixtures.redis_prefix             → a UNIQUE test namespace (cleanup-safe)
#   OrchestratorFixtures.cleanup(conn, user_id:)  → reverse-FK teardown (the pipeline
#       sweep extended with the quest-graph + report + ladder rows)
module OrchestratorFixtures
  module_function

  # The tenancy mint: user + quest ONLY — no phase, no session row (the
  # runner's briefing-init state IS "no phases row yet", PHASE 0 note 6; the
  # pipeline mint's phase/session rows would mask it). Phase/session rows are
  # minted explicitly by the tests that need them.
  def mint_tenancy(conn, topic: "Orchestrator fixture quest", state: "active",
                   web_call_budget: 16, token_budget: 1_000_000, spend_budget_usd: 1.0,
                   process_config: {}, model_config: {})
    user_id = conn[:users].insert(handle: "gh-#{SecureRandom.hex(6)}",
                                  github_uid: SecureRandom.uuid,
                                  username: "u#{SecureRandom.hex(6)}",
                                  name: "Orchestrator Fixture", created_at: Time.now)
    quest_id = conn[:quests].insert(
      user_id: user_id, topic: topic, state: state,
      web_call_budget: web_call_budget, token_budget: token_budget,
      spend_budget_usd: spend_budget_usd,
      process_config: Sequel.lit("?::jsonb", JSON.generate(process_config)),
      model_config: Sequel.lit("?::jsonb", JSON.generate(model_config))
    )
    {user_id: user_id, quest_id: quest_id}
  end

  # A quest with its steering config (the budgets are the quest columns, L9;
  # process_config is the quest-local config carrier, R-060/R-064).
  def mint_quest(conn, user_id:, topic: "Orchestrator fixture quest", state: "active",
                 web_call_budget: 16, token_budget: 1_000_000, spend_budget_usd: 1.0,
                 process_config: {}, model_config: {})
    quest_id = conn[:quests].insert(
      user_id: user_id, topic: topic, state: state, web_call_budget: web_call_budget,
      token_budget: token_budget, spend_budget_usd: spend_budget_usd,
      process_config: Sequel.lit("?::jsonb", JSON.generate(process_config)),
      model_config: Sequel.lit("?::jsonb", JSON.generate(model_config))
    )
    quest_id
  end

  # A staged source with a snapshot blob (the anchoring target) — the
  # content-addressed row + quest membership (the ToolRig mint's shape).
  def mint_source(conn, user_id:, quest_id:, snapshot:, role: "citable",
                  title: "Fixture source")
    urn = "kb:src:" + Kquest::Pipeline::Base58.encode(SecureRandom.bytes(12))[0, 10]
    sha = Digest::SHA256.hexdigest(snapshot)
    Kquest::BlobUploader.store(StringIO.new(snapshot), kind: :snapshot, user: user_id,
                               source_urn: urn)
    source_id = conn[:sources].insert(
      user_id: user_id, url: "https://example.test/#{urn}",
      canonical_url: "https://example.test/#{urn}", urn: urn, title: title, role: role,
      fetched_at: Time.now, snapshot_sha256: sha, raw_sha256: sha,
      snapshot_char_count: snapshot.length
    )
    conn[:quest_sources].insert(quest_id: quest_id, source_id: source_id, user_id: user_id)
    {id: source_id, urn: urn, text: snapshot}
  end

  def redis_endpoint
    url = ENV["REDIS_URL"]
    raise "REDIS_URL must be set (an isolated, non-zero test database)" unless url

    Async::Redis::Endpoint.parse(url)
  end

  def redis_client
    Async::Redis::Client.new(redis_endpoint)
  end

  # A UNIQUE test namespace — every registry/publisher key in the suite lands
  # under it and the cleanup sweeps it (never dev's db 0 keys; the suite's
  # REDIS_URL database is flushed at boot by test_helper).
  def redis_prefix
    "kquest:test:#{SecureRandom.hex(6)}"
  end

  def cleanup_redis(client, prefix)
    pattern = "#{prefix}*"
    cursor = "0"
    loop do
      cursor, keys = client.call("SCAN", cursor, "MATCH", pattern, "COUNT", 200)
      client.call("DEL", *keys) unless keys.empty?
      break if cursor == "0" || cursor.to_i.zero?
    end
  end

  # A full-table sweep (the substrate action tests' setup_db discipline,
  # extended): for the tests whose view is GLOBAL (the launcher, the slice
  # routes) — the shared test db starts empty.
  def sweep_all(conn)
    conn[:report_citations].delete
    conn[:report_versions].delete
    conn[:conflict_sources].delete
    conn[:conflicts].delete
    conn[:evidence_edges].delete
    conn[:evidence].delete
    conn[:claim_derivations].delete
    conn[:tool_calls].delete
    conn[:quest_lifecycle_events].delete
    conn[:emb_minilm_ab_384].delete
    conn[:emb_bge_m3_1024].delete
    conn[:embed_jobs].delete
    conn[:usage_events].delete
    conn[:ladder_passes].delete
    conn[:chunks].delete
    conn[:quest_sources].delete
    conn[:sources].delete
    conn[:frontier_entries].delete
    conn[:claims].delete
    conn[:sessions].delete
    conn[:phases].delete
    conn[:quests].delete
    conn[:users].delete
    nil
  end

  # Reverse-FK teardown — the pipeline sweep extended with the quest-graph
  # rows the engine/orchestrator create (the tool tests' preamble order).
  def cleanup(conn, user_id:)
    return unless user_id

    conn[:report_citations].where(user_id: user_id).delete
    conn[:report_versions].where(user_id: user_id).delete
    conn[:conflict_sources].where(user_id: user_id).delete
    conn[:conflicts].where(user_id: user_id).delete
    conn[:evidence_edges].where(user_id: user_id).delete
    conn[:evidence].where(user_id: user_id).delete
    conn[:claim_derivations].where(user_id: user_id).delete
    conn[:tool_calls].where(user_id: user_id).delete
    conn[:quest_lifecycle_events].where(user_id: user_id).delete
    conn[:emb_minilm_ab_384].where(user_id: user_id).delete
    conn[:emb_bge_m3_1024].where(user_id: user_id).delete
    conn[:embed_jobs].where(user_id: user_id).delete
    conn[:usage_events].where(user_id: user_id).delete
    # ladder_passes is NOT swept here: the ladder rungs record their PASS rows
    # INSIDE the rig lifecycle (teardown_rig runs cleanup before the caller
    # asserts), and the evidence row must survive its own rig's teardown —
    # the LadderTest teardown owns that sweep (sweep_all keeps it for the
    # global-view tests).
    conn[:chunks].where(user_id: user_id).delete
    conn[:quest_sources].where(user_id: user_id).delete
    conn[:sources].where(user_id: user_id).delete
    conn[:frontier_entries].where(user_id: user_id).delete
    conn[:claims].where(user_id: user_id).delete
    conn[:sessions].where(user_id: user_id).delete
    conn[:phases].where(user_id: user_id).delete
    conn[:quests].where(user_id: user_id).delete
    conn[:users].where(id: user_id).delete
    # The engine + tool config tables are global config data: every consumer
    # upserts its own rows; the seeds' delete+insert law re-heals at the next
    # `hanami db prepare` (the PipelineFixtures law, extended verbatim).
    conn[:llm_providers].delete
    conn[:engine_config].delete
    conn[:subagent_profiles].delete
    conn[:tool_config].delete
    conn[:web_providers].delete
    nil
  end
end
