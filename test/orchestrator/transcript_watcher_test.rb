# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/orchestrator/transcript_watcher"
require_relative "../../lib/kquest/orchestrator/event_publisher"
require_relative "../../lib/kquest/engine/transcript_ledger"

# The transcript watcher (I07 DR-07's byte-accurate LIVE half): byte growth
# read through the landed TranscriptLedger sink seam (the SAME bytes the
# ledger appends — never a second copy), the four I06 stop-rule keys
# evaluated, the `watcher.bytes` census + `assurance_alert` signals emitted,
# and the NEVER-KILLS negative (the watcher never ends a session, never
# transitions — eval-not-binding).
class TranscriptWatcherTest < Minitest::Test
  def setup
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    @quest_id = @tenancy[:quest_id]
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

  # A REAL TranscriptLedger on its in-memory sink — the watcher reads the
  # same bytes the ledger appends (no second copy anywhere in this test).
  def mint_ledger(bytes_text)
    session_id = conn[:sessions].insert(user_id: @user_id, quest_id: @quest_id,
                                        phase_id: mint_phase, mode: "autonomous",
                                        driver: "orchestrator", model: "test-model")
    ledger = Kquest::Engine::TranscriptLedger.new(
      conn: conn, session: {id: session_id, user_id: @user_id, quest_id: @quest_id,
                            phase_id: @phase_id, model: "test-model"},
      sink: Kquest::Engine::TranscriptLedger::MemorySink.new
    )
    ledger.sink.append(ledger.location, bytes_text)
    [session_id, ledger]
  end

  def mint_phase
    @phase_id ||= conn[:phases].insert(user_id: @user_id, quest_id: @quest_id,
                                       kind: "decompose")
  end

  def config(overrides = {})
    base = Kquest::Engine::DEFAULT_CONFIG.transform_values { |v| {value: v, mode: "advisory"} }
    overrides.each { |k, v| base[k] = {value: v, mode: "advisory"} }
    base
  end

  def watcher(ledgers, cfg = config)
    Kquest::Orchestrator::TranscriptWatcher.new(
      quest_id: @quest_id, ledger_for: -> { ledgers }, publisher: @publisher, config: cfg
    )
  end

  def stream_records(prefix)
    Sync do
      (@redis.call("XRANGE", "#{prefix}:sse:quest:#{@quest_id}", "-", "+") || [])
        .map { |_id, fields| fields.each_slice(2).to_h }
    end
  end

  def test_census_reads_bytes_through_the_ledger_sink_seam
    session_id, ledger = mint_ledger("x" * 500)
    w = watcher({session_id => ledger})

    records = Sync { w.census }
    record = records.first
    assert_equal 500, record[:transcript_bytes], "the SAME bytes the ledger appended"
    assert_equal 500, w.bytes_for(session_id)

    ledger.sink.append(ledger.location, "y" * 300)
    Sync { w.census(at: Time.now + 2) }
    assert_equal 800, w.bytes_for(session_id)
    assert_equal 300, w.growth_for(session_id, 10), "the growth over the window"
  ensure
    conn[:sessions].where(id: session_id).delete if session_id
  end

  def test_watcher_bytes_census_event_publishes
    session_id, ledger = mint_ledger("x" * 120)
    w = watcher({session_id => ledger})

    Sync { w.census }
    entries = stream_records(@prefix).select { |e| e["type"] == "watcher.bytes" }
    assert_equal 1, entries.size
    data = JSON.parse(entries.first["data"])
    assert_equal 120, data["transcript_bytes"]
    assert_equal 0, data["growth_bytes"]
    assert_equal 1200, data["window_s"]
  ensure
    conn[:sessions].where(id: session_id).delete if session_id
  end

  def test_slow_stall_signal_under_the_i06_keys
    # growth 50B < floor 100B over the 1200s window → the byte-accurate
    # slow-stall alert under engine.slow_stall_bytes.
    session_id, ledger = mint_ledger("x" * 50)
    cfg = config("engine.slow_stall_bytes" => 100, "engine.slow_stall_window_s" => 1200)
    w = watcher({session_id => ledger}, cfg)

    Sync { w.census(at: Time.now) }
    Sync { w.census(at: Time.now + 1201) }
    entries = stream_records(@prefix).select { |e| e["type"] == "assurance_alert" }
    assert_operator entries.size, :>=, 1, "the alert fired"
    data = JSON.parse(entries.last["data"])
    assert_equal "engine.slow_stall_bytes", data["predicate"]
  ensure
    conn[:sessions].where(id: session_id).delete if session_id
  end

  def test_ceiling_bands_signal_warn_then_hard_under_the_i06_keys
    warn_bytes = 450_000
    hard_bytes = 496_000
    session_id, ledger = mint_ledger("x" * (warn_bytes - 1))
    cfg = config("engine.transcript_ceiling_warn_bytes" => warn_bytes,
                 "engine.transcript_ceiling_hard_bytes" => hard_bytes)
    w = watcher({session_id => ledger}, cfg)

    Sync { w.census(at: Time.now) }
    assert_empty stream_records(@prefix).select { |e| e["type"] == "assurance_alert" },
                 "below the warn band: quiet"

    ledger.sink.append(ledger.location, "y" * 2) # 450001 → warn
    Sync { w.census(at: Time.now + 1) }
    ledger.sink.append(ledger.location, "z" * (hard_bytes - warn_bytes - 1)) # 496000 → hard
    Sync { w.census(at: Time.now + 2) }

    alerts = stream_records(@prefix).select { |e| e["type"] == "assurance_alert" }
    bands = alerts.map { |e| JSON.parse(e["data"])["predicate"] }
    assert_includes bands, "engine.transcript_ceiling_warn_bytes"
    assert_includes bands, "engine.transcript_ceiling_hard_bytes"
  ensure
    conn[:sessions].where(id: session_id).delete if session_id
  end

  def test_the_watcher_never_kills_never_ends_never_transitions
    session_id, ledger = mint_ledger("x" * (496_001)) # past the HARD ceiling
    cfg = config("engine.transcript_ceiling_hard_bytes" => 496_000)
    w = watcher({session_id => ledger}, cfg)

    Sync { w.census(at: Time.now) }
    Sync { w.census(at: Time.now + 7200) } # far past every window

    row = conn[:sessions].where(id: session_id).first
    assert_nil row[:ended_at], "FM-18: the watcher never ends a session"
    assert_equal "active", conn[:quests].where(id: @quest_id).get(:state),
                 "the watcher never transitions the quest"
    assert_empty conn[:phases].where(quest_id: @quest_id).where { state =~ "failed" }.to_a
    alerts = stream_records(@prefix).select { |e| e["type"] == "assurance_alert" }
    assert_operator alerts.size, :>=, 1, "it SIGNALS (eval-not-binding)"
  ensure
    conn[:sessions].where(id: session_id).delete if session_id
  end

  def test_unattended_window_signals_from_the_census_timestamps
    session_id, ledger = mint_ledger("x" * 10)
    cfg = config("engine.unattended_pause_s" => 3600)
    w = watcher({session_id => ledger}, cfg)

    Sync { w.census(at: Time.now) }
    assert_empty w.growth_for(session_id, 60) == 0 ? [] : [1]
    # No growth for 3601s of census time → the unattended signal, no pause.
    Sync { w.census(at: Time.now + 3601) }
    alerts = stream_records(@prefix).select { |e| e["type"] == "assurance_alert" }
    assert_operator alerts.size, :>=, 1
    assert_equal "engine.unattended_pause_s", JSON.parse(alerts.last["data"])["predicate"]
  ensure
    conn[:sessions].where(id: session_id).delete if session_id
  end
end
