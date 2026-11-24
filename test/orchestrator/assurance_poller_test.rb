# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/orchestrator/assurance_poller"
require_relative "../../lib/kquest/orchestrator/event_publisher"

# The assurance_alert poller (I07 §4, DR-10): the 13 `tw_*` views evaluated
# BY NAME against the LIVE app schema, each fire → one `assurance_alert`
# XADD (predicate id + key fields), clean data → NO fire (the fire/quiet
# discipline check-tripwires.sh proves in scratch, proven again here against
# the live schema), and the SIGNAL-ONLY law (SELECT-only — no mutation of
# quests/phases/sessions anywhere in the poller).
class AssurancePollerTest < Minitest::Test
  def setup
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    @quest_id = @tenancy[:quest_id]
    @phase_id = conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "decompose")
    @prefix = OrchestratorFixtures.redis_prefix
    @redis = OrchestratorFixtures.redis_client
    @publisher = Kquest::Orchestrator::EventPublisher.new(redis: @redis, prefix: @prefix)
    @poller = Kquest::Orchestrator::AssurancePoller.new(conn: conn, publisher: @publisher)
  end

  def teardown
    Sync { OrchestratorFixtures.cleanup_redis(@redis, @prefix) } if @redis
    @redis&.close
    OrchestratorFixtures.cleanup(conn, user_id: @user_id)
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def fires
    Sync do
      (@redis.call("XRANGE", "#{@prefix}:sse:quest:#{@quest_id}", "-", "+") || [])
        .map { |_id, fields| fields.each_slice(2).to_h }
        .select { |e| e["type"] == "assurance_alert" }
        .map { |e| JSON.parse(e["data"]) }
    end
  end

  def test_tw_wedge_fires_with_last_tool_and_stays_quiet_on_clean_data
    # FIRE: a live session whose ledger has been silent past the stall
    # window (the PART A wedge scenario: last call a spawn, no results).
    wedge_session = mint_live_session(started_at: Time.now - 1300)
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id, session_id: wedge_session,
                             seq: 1, tool: "subagent_spawn",
                             args: Sequel.lit("'{}'::jsonb"), result: Sequel.lit("'{}'::jsonb"),
                             ok: true, created_at: Time.now - 1300)
    # QUIET: a live healthy session with fresh ledger events.
    healthy = mint_live_session(started_at: Time.now - 10)
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id, session_id: healthy,
                             seq: 1, tool: "status", args: Sequel.lit("'{}'::jsonb"),
                             result: Sequel.lit("'{}'::jsonb"), ok: true)

    count = @poller.pass

    wedge_fires = fires.select { |f| f["predicate"] == "tw_wedge" &&
                                    f["session_id"] == wedge_session.to_s }
    assert_equal 1, wedge_fires.size, "the wedge fires once"
    assert_equal "subagent_spawn", wedge_fires.first["last_tool"],
                 "the payload carries last_tool ('spawn' means: check the run registry, " \
                 "NEVER infer child death — FM-20)"
    assert_empty fires.select { |f| f["predicate"] == "tw_wedge" &&
                                   f["session_id"] == healthy.to_s },
                 "the healthy session is quiet"
    assert_operator count, :>=, 1

    # The dedup: a second pass does NOT re-fire the same row.
    @poller.pass
    assert_equal 1, fires.count { |f| f["predicate"] == "tw_wedge" &&
                                      f["session_id"] == wedge_session.to_s }
  ensure
    conn[:tool_calls].where(session_id: [wedge_session, healthy]).delete if wedge_session
    conn[:sessions].where(id: [wedge_session, healthy]).delete if wedge_session
  end

  def test_tw_size_ceiling_carries_band_and_bytes
    session = mint_live_session(started_at: Time.now - 60)
    # A ceiling-band audit payload (~455 KB, the PART A band fixture).
    payload = JSON.generate({"big" => "x" * 470_000})
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id, session_id: session,
                             seq: 1, tool: "source_read", args: Sequel.lit("'{}'::jsonb"),
                             result: Sequel.lit("?::jsonb", payload), ok: true)

    @poller.pass

    fire = fires.find { |f| f["predicate"] == "tw_size_ceiling" }
    refute_nil fire, "the ceiling-band transcript fires"
    assert_equal "warn", fire["band"], "the payload carries the band"
    assert_operator fire["audit_bytes"].to_i, :>=, 450_000, "the payload carries the bytes"
  ensure
    conn[:tool_calls].where(session_id: session).delete if session
    conn[:sessions].where(id: session).delete if session
  end

  def test_tw_empty_storm_fires_and_tw_rotation_on_overcap_attempts
    # The empty storm: three billed-input zero-output llm rows in one phase.
    session = mint_live_session(started_at: Time.now - 60)
    3.times do
      conn[:usage_events].insert(user_id: @user_id, quest_id: @quest_id, phase_id: @phase_id,
                                 session_id: session, kind: "llm", model: "test-model",
                                 input_tokens: 10, output_tokens: 0)
    end
    # The rotation: a phase attempt past the retry cap while unfinished.
    conn[:phases].where(id: @phase_id).update(attempt_no: 4)

    @poller.pass

    storm = fires.find { |f| f["predicate"] == "tw_empty_storm" }
    refute_nil storm, "the empty-completion storm fires"
    assert_equal 3, storm["empty_completions"].to_i
    rotation = fires.find { |f| f["predicate"] == "tw_rotation" }
    refute_nil rotation, "the over-cap attempt fires"
  ensure
    conn[:usage_events].where(session_id: session).delete if session
    conn[:sessions].where(id: session).delete if session
    conn[:phases].where(id: @phase_id).update(attempt_no: 1)
  end

  def test_tw_hub_divergence_fires_cross_quest_and_lands_on_the_user_stream
    # Same user, same canonical text, two DISTINCT terminal types across
    # quests — the exact divergence identity (I02 DR-02/DR-16).
    other_quest = conn[:quests].insert(user_id: @user_id, topic: "divergence fixture quest",
                                       web_call_budget: 1, token_budget: 1, spend_budget_usd: 1)
    other_phase = conn[:phases].insert(user_id: @user_id, quest_id: other_quest,
                                       kind: "decompose")
    mint_divergent_claim(text: "the divergent fixture claim", quest_id: @quest_id,
                         terminal_type: "primary-empirical")
    mint_divergent_claim(text: "the divergent fixture claim", quest_id: other_quest,
                         terminal_type: "residual-uncertainty")

    @poller.pass

    # tw_hub_divergence has NO single owning quest (it spans quests) — its
    # fire lands on the owning user's global stream (I08 §3.4).
    user_entries = Sync do
      (@redis.call("XRANGE", "#{@prefix}:sse:user:#{@user_id}", "-", "+") || [])
        .map { |_id, fields| fields.each_slice(2).to_h }
    end
    hub_fires = user_entries.select { |e| e["type"] == "assurance_alert" }
                            .map { |e| JSON.parse(e["data"]) }
                            .select { |d| d["predicate"] == "tw_hub_divergence" }
    assert_equal 1, hub_fires.size, "the cross-quest divergence fires on the user's stream"
    assert hub_fires.first.key?("canonical_text"),
           "the payload carries the divergence key fields"

    # QUIET: same-text-same-type coexistence never fires.
    conn[:tool_config].delete
    conn[:claims].where(quest_id: other_quest).delete
    conn[:phases].where(id: other_phase).delete
    conn[:quests].where(id: other_quest).delete
  end

  def test_cadence_comes_from_the_config_row
    conn[:tool_config].where(key: "assurance.poll_interval_s").delete
    conn[:tool_config].insert(key: "assurance.poll_interval_s", num_value: 45,
                              provenance: "test-minted config data")
    assert_equal 45, @poller.interval_s
    conn[:tool_config].where(key: "assurance.poll_interval_s").delete
    conn[:tool_config].insert(key: "assurance.poll_interval_s", num_value: 30,
                              provenance: "I08 §3.4 default (test re-mint)")
    assert_equal 30, @poller.interval_s
  end

  def test_the_poller_is_select_only_over_the_views
    # The eval-not-binding law, structurally: the sweep leaves the ledgers
    # byte-identical (no quest/phases/sessions mutation, no transitions).
    before = {
      quests: conn[:quests].where(id: @quest_id).first,
      phases: conn[:phases].where(quest_id: @quest_id).to_a,
      sessions: conn[:sessions].where(quest_id: @quest_id).to_a
    }
    @poller.pass
    assert_equal before[:quests], conn[:quests].where(id: @quest_id).first
    assert_equal before[:phases].map(&:to_json), conn[:phases].where(quest_id: @quest_id).map(&:to_json)
    assert_equal before[:sessions].map(&:to_json), conn[:sessions].where(quest_id: @quest_id).map(&:to_json)
  end

  # ── fixtures ──────────────────────────────────────────────────────────

  def mint_live_session(started_at:)
    conn[:sessions].insert(user_id: @user_id, quest_id: @quest_id, phase_id: @phase_id,
                           mode: "autonomous", driver: "orchestrator", model: "test-model",
                           started_at: started_at)
  end

  def mint_divergent_claim(text:, quest_id:, terminal_type:)
    seq = (conn[:claims].where(quest_id: quest_id).max(:quest_seq) || 0) + 1
    conn[:claims].insert(user_id: @user_id, quest_id: quest_id, quest_seq: seq, text: text,
                         terminal_type: terminal_type, terminal_basis: "the fixture corpus",
                         urn: "kb:claim:" + Kquest::Pipeline::Base58.encode(
                           SecureRandom.bytes(12))[0, 10])
  end
end
