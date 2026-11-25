# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "async/redis"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/orchestrator/phase_runner"
require_relative "../../lib/kquest/orchestrator/phase_contract"
require_relative "../../lib/kquest/engine/session_supervisor"

# The phase runner (I06 consumed exactly; I08 §2.1): it EVALUATES the landed
# `phase_transitions` (ordinal order = priority, first match, wildcards) and
# `stop_rules` tables as LIVE config re-read at EVERY boundary; advisory
# crossings signal and never route, hard crossings fire the transition row;
# every stop firing emits all four loud parts; the boundary sweep reads ONLY
# the I05 parity fields. All keyless (the transition table is mutated and
# restored inside the tests — it is config data, the seeds re-heal).
class PhaseRunnerTest < Minitest::Test
  def setup
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    @quest_id = @tenancy[:quest_id]
    @stderr = StringIO.new
    @prefix = OrchestratorFixtures.redis_prefix
    @redis = OrchestratorFixtures.redis_client
    @publisher = Kquest::Orchestrator::EventPublisher.new(redis: @redis, prefix: @prefix)
    @runner = Kquest::Orchestrator::PhaseRunner.new(
      conn: conn, supervisor: Kquest::Engine::SessionSupervisor.new(conn: conn),
      publisher: @publisher, stderr: @stderr
    )
  end

  def teardown
    Sync { OrchestratorFixtures.cleanup_redis(@redis, @prefix) } if @redis
    @redis&.close
    restore_transitions
    OrchestratorFixtures.cleanup(conn, user_id: @user_id)
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def quest_row
    conn[:quests].where(id: @quest_id).first
  end

  def complete_phase(kind, process_config: nil)
    if process_config
      conn[:quests].where(id: @quest_id)
                   .update(process_config: Sequel.lit("?::jsonb", JSON.generate(process_config)))
    end
    round = conn[:phases].where(quest_id: @quest_id, kind: kind).count + 1
    conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: kind, round_no: round,
                         state: "complete", started_at: Time.now, ended_at: Time.now)
  end

  def boundary(phase_id, event: "phase_complete")
    phase = conn[:phases].where(id: phase_id).first
    @runner.evaluate_boundary(quest: quest_row, phase: phase,
                              config: @runner.send(:read_config, quest_row), event: event)
  end

  # Restore the landed transition rows from the repo's own TSV (the seeds'
  # law source) — the mutated-table test deletes them.
  def restore_transitions
    return if conn[:phase_transitions].count >= 27

    conn[:phase_transitions].delete
    lines = File.readlines(File.expand_path("../../config/db/seeds/transitions.tsv", __dir__),
                           chomp: true).drop(1)
    lines.each_with_index do |line, i|
      from, event, guard, to, exit_kind, evidence = line.split("\t", -1)
      conn[:phase_transitions].insert(ordinal: i + 1, from_phase: from, event: event,
                                      guard: guard, to_phase: to, phase_kind_exit: exit_kind,
                                      evidence: evidence)
    end
  end

  def event_types
    Sync do
      (@redis.call("XRANGE", "#{@prefix}:sse:quest:#{@quest_id}", "-", "+") || [])
        .map { |_id, f| f.each_slice(2).to_h["type"] }
    end
  end

  # ── the transition table is LIVE CONFIG (P-PRIO / the mutated-table law) ──

  def test_transition_priority_follows_mutated_table_row
    phase_id = complete_phase("decompose")
    snapshot = conn[:phase_transitions].order(:ordinal).to_a
    begin
      # MUTATE the table: the decompose tail now routes to verification on a
      # bare `none` guard at the TOP priority — the runner must follow the
      # MUTATED table, never any encoded expectation.
      conn[:phase_transitions].delete
      conn[:phase_transitions].insert(
        ordinal: 1, from_phase: "decompose", event: "phase_complete", guard: "none",
        to_phase: "verification", phase_kind_exit: "verification-terminal", evidence: "test-mutated"
      )

      verdict = boundary(phase_id)

      assert_equal :entered, verdict
      next_phase = conn[:phases].where(quest_id: @quest_id).order(Sequel.desc(:created_at)).first
      assert_equal "verification", next_phase[:kind],
                   "the runner followed the MUTATED table row (first match in ordinal order)"
    ensure
      conn[:phase_transitions].delete
      snapshot.each do |row|
        conn[:phase_transitions].insert(
          ordinal: row[:ordinal], from_phase: row[:from_phase], event: row[:event],
          guard: row[:guard], to_phase: row[:to_phase],
          phase_kind_exit: row[:phase_kind_exit], evidence: row[:evidence]
        )
      end
    end
  end

  # ── the per-phase-boundary gates (the I06 §3 vocabulary, by name) ─────

  def test_decompose_boundary_exits_to_frontier_build_through_the_mass_floor_gate
    phase_id = complete_phase("decompose")
    verdict = boundary(phase_id)

    assert_equal :entered, verdict
    next_phase = conn[:phases].where(quest_id: @quest_id).order(Sequel.desc(:created_at)).first
    assert_equal "frontier-build", next_phase[:kind]
    assert_match(/FRONTIER_BUILD/, @stderr.string, "the entry event is loud (I06 §2.2)")
  end

  def test_decompose_boundary_repeats_while_sources_remain_unmined
    OrchestratorFixtures.mint_source(conn, user_id: @user_id, quest_id: @quest_id,
                                     snapshot: "unmined fixture text")
    phase_id = complete_phase("decompose")
    verdict = boundary(phase_id)

    assert_equal :entered, verdict
    next_phase = conn[:phases].where(quest_id: @quest_id).order(Sequel.desc(:created_at)).first
    assert_equal "decompose", next_phase[:kind], "the counter-exit re-enters decompose"
  end

  def test_descent_boundary_exits_through_mass_decay_primary
    # Ten completed descent boundaries with mass decayed to <= cut × peak
    # (the I06 §4.1 rule: 0.25 × peak at EACH of the last window=10).
    peak = 100
    10.times do |i|
      conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "descent",
                           round_no: i + 1, state: "complete", started_at: Time.now,
                           ended_at: Time.now, frontier_open: 4,
                           frontier_mass: i.zero? ? peak : 20)
    end
    phase_id = complete_phase("descent")
    verdict = boundary(phase_id)

    assert_equal :entered, verdict
    next_phase = conn[:phases].where(quest_id: @quest_id).order(Sequel.desc(:created_at)).first
    assert_equal "synthesis", next_phase[:kind], "mass-decay-primary routes to synthesis"
  end

  def test_three_zeros_violation_stops_loud_graph_invalid
    # A bare claim (no terminal, no derivation, no open frontier entry)
    # refuses the boundary: graph_invalid → stopped (the ONE stop that
    # cannot route to synthesis).
    conn[:claims].insert(user_id: @user_id, quest_id: @quest_id, quest_seq: 1,
                         text: "a bare fixture claim",
                         urn: "kb:claim:" + Kquest::Pipeline::Base58.encode(
                           SecureRandom.bytes(12))[0, 10])
    phase_id = complete_phase("decompose")
    verdict = boundary(phase_id)

    assert_equal :stopped, verdict
    assert_equal "stopped", conn[:quests].where(id: @quest_id).get(:state)
    lifecycle = conn[:quest_lifecycle_events].where(quest_id: @quest_id)
                                             .order(Sequel.desc(:occurred_at)).first
    assert_equal %w[active stopped], [lifecycle[:from_state], lifecycle[:to_state]]
    assert_includes @stderr.string, "PROCESS_STOP:", "the loud line is on the stderr channel"
  end

  # ── the stop-rule sweep: modes, signals, routes ───────────────────────

  def web_calls(n)
    round = conn[:phases].where(quest_id: @quest_id, kind: "descent").count + 1
    session_id = conn[:sessions].insert(user_id: @user_id, quest_id: @quest_id,
                                        phase_id: conn[:phases].insert(
                                          user_id: @user_id, quest_id: @quest_id,
                                          kind: "descent", round_no: round
                                        ), mode: "autonomous", driver: "orchestrator",
                                        model: "test-model")
    n.times do |i|
      conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id, session_id: session_id,
                               seq: i + 1, tool: "web_search", args: Sequel.lit("'{}'::jsonb"),
                               result: Sequel.lit("'{}'::jsonb"), ok: true)
    end
  end

  def test_advisory_crossing_signals_never_routes
    conn[:quests].where(id: @quest_id).update(web_call_budget: 1)
    web_calls(2) # 2 ok web calls > the 1-call budget line
    phase_id = complete_phase("descent")

    verdict = boundary(phase_id)

    # The ADVISORY crossing: the loud boundary event + the assurance signal —
    # NEVER a route (DR-09); the boundary continues to the transition table.
    alerts = event_types.select { |t| t == "assurance_alert" }
    assert_operator alerts.size, :>=, 1, "the crossing signalled"
    assert_equal "active", conn[:quests].where(id: @quest_id).get(:state),
                 "an advisory crossing never routes"
    refute_includes @stderr.string, "PROCESS_STOP:",
                    "the loud PROCESS_STOP line is the STOP's shape, not the advisory echo"
  end

  def test_hard_crossing_fires_the_transition_row
    conn[:quests].where(id: @quest_id).update(web_call_budget: 1)
    web_calls(2)
    phase_id = complete_phase("descent", process_config:
      {"modes" => {"quest.web_call_budget" => "hard"}})

    verdict = boundary(phase_id)

    assert_equal :entered, verdict
    next_phase = conn[:phases].where(quest_id: @quest_id).order(Sequel.desc(:created_at)).first
    assert_equal "synthesis", next_phase[:kind],
                 "the HARD crossing fired the any-work-phase budget_exhausted row " \
                 "(route-to-synthesis — the never-reportless law)"
    assert_includes event_types, "quest.stop", "the stop surfaces as an alert-class event"
  end

  def test_stop_firing_is_loud_all_four_parts
    conn[:quests].where(id: @quest_id).update(web_call_budget: 1)
    web_calls(2)
    phase_id = complete_phase("descent", process_config:
      {"modes" => {"quest.web_call_budget" => "hard"}})

    boundary(phase_id)

    # Part 1: the composed stderr line.
    line = @stderr.string.lines.find { |l| l.start_with?("PROCESS_STOP:") }
    refute_nil line, "part 1: the composed PROCESS_STOP line"
    assert_match(/PROCESS_STOP: SR-02 at phase \d+ \(descent\) — .+ — route: route-to-synthesis/, line)

    # Part 2: the phases row result marker.
    raw = conn[:phases].where(id: phase_id).get(:result)
    form = raw.is_a?(Hash) ? JSON.generate(raw) : raw.to_s
    assert_includes form, '"stop"', "part 2: the phases-row result marker"
    assert_includes form, "SR-02", "the marker names the fired rule"

    # Part 3: the quest.stop SSE event (alert-class).
    stops = Sync do
      (@redis.call("XRANGE", "#{@prefix}:sse:quest:#{@quest_id}", "-", "+") || [])
        .map { |_id, f| f.each_slice(2).to_h }
        .select { |e| e["type"] == "quest.stop" }
    end
    assert_equal 1, stops.size, "part 3: the quest.stop event"
    stop_data = JSON.parse(stops.first["data"])
    assert_equal "SR-02", stop_data["rule_id"]
    assert_includes stop_data["reason"], "quest.web_call_budget",
                    "the crossed line's config key names the stop (the marker's key)"

    # Part 4: the stop marker carried into the synthesis prompt as provenance.
    # (The phase task text rows are config data the cleanup sweep empties —
    # this test mints its own, the standing law.)
    conn[:tool_config].where(key: "phase_task_text.synthesis").delete
    conn[:tool_config].insert(key: "phase_task_text.synthesis",
                              text_value: "Write the report FROM THE GRAPH.",
                              provenance: "I06 §9.4 (test-minted)")
    synthesis = conn[:phases].where(quest_id: @quest_id, kind: "synthesis").first
    contract = Kquest::Orchestrator::PhaseContract.new(
      conn: conn, quest: quest_row, phase: synthesis,
      session: {id: SecureRandom.uuid, user_id: @user_id, quest_id: @quest_id,
                phase_id: synthesis[:id], model: "test-model"},
      config: @runner.send(:read_config, quest_row)
    )
    instructions = contract.assemble_context(0)[:instructions]
    assert_includes instructions, "PROCESS_STOP: SR-02",
                   "part 4: the synthesis prompt carries the stop marker as provenance"
  end

  def test_pause_route_ledgers_the_transition
    # SR-16's hard ceiling → transcript_ceiling → paused (pause-and-present):
    # the route is a lifecycle target → the ledgered active→paused event.
    phase_id = complete_phase("decompose", process_config:
      {"modes" => {"engine.transcript_ceiling_hard_bytes" => "hard"}})
    # Plant the transcript_bytes guard value over the hard line.
    phase = conn[:phases].where(id: phase_id).first
    @runner.evaluate_boundary(quest: quest_row, phase: phase,
                              config: @runner.send(:read_config, quest_row),
                              event: "transcript_ceiling")

    assert_equal "paused", conn[:quests].where(id: @quest_id).get(:state)
    lifecycle = conn[:quest_lifecycle_events].where(quest_id: @quest_id)
                                             .order(Sequel.desc(:occurred_at)).first
    assert_equal %w[active paused], [lifecycle[:from_state], lifecycle[:to_state]]
    assert_equal "orchestrator", lifecycle[:actor]
  end

  # ── P-REREAD: the config is re-read at EVERY boundary ─────────────────

  def test_config_is_reread_at_every_boundary
    conn[:quests].where(id: @quest_id).update(web_call_budget: 1)
    web_calls(2)
    phase_id = complete_phase("descent") # advisory (no modes in process_config)

    first = boundary(phase_id)
    assert_equal :entered, first, "advisory crossing: the boundary continues"
    advisory_alerts = event_types.count { |t| t == "assurance_alert" }

    # The operator edits the config AT PAUSE (the only door, D5): the web
    # line flips to hard. The NEXT boundary re-reads the FULL live config —
    # the same numbers now route.
    phase2 = complete_phase("descent", process_config:
      {"modes" => {"quest.web_call_budget" => "hard"}})
    second = boundary(phase2)

    assert_equal :entered, second
    next_phase = conn[:phases].where(quest_id: @quest_id).order(Sequel.desc(:created_at)).first
    assert_equal "synthesis", next_phase[:kind],
                 "the re-read config's HARD mode fired the transition row"
    assert_operator event_types.count { |t| t == "quest.stop" }, :>=, 1
    _ = advisory_alerts
  end

  # ── the §8 amendment's runner branch (AC12) ─────────────────────────

  # A fake executor for the branch tests (the branch's own law is the
  # DELEGATION + the verdict mapping; the exchange's internals are the
  # BriefingExecutorTest's and the integration test's subject).
  class FakeExecutor
    attr_reader :served, :exchanged, :session

    def initialize(rows:, error: nil)
      @rows = rows
      @error = error
      @served = 0
      @exchanged = []
    end

    def consume_next!(quest:, session:)
      @served += 1
      @quest = quest
      @session = session
      @rows.shift
    end

    def exchange!(quest:, session:, row:)
      @exchanged << row
      raise @error if @error

      :completed
    end
  end

  def open_operator_session
    phase = conn[:phases].where(quest_id: @quest_id, kind: "decompose", round_no: 1).first ||
            conn[:phases].where(id: conn[:phases].insert(
              user_id: @user_id, quest_id: @quest_id, kind: "decompose",
              round_no: 1, state: "pending"
            )).first
    conn[:sessions].insert(user_id: @user_id, quest_id: @quest_id, phase_id: phase.fetch(:id),
                           mode: "interactive", driver: "operator", model: "test-provider")
  end

  def stub_executor(fake)
    @runner.instance_variable_set(:@briefing_executor, fake)
  end

  def test_open_operator_session_branches_first_and_serves_the_queue
    phase_id = conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "decompose",
                                    round_no: 1, state: "pending")
    session_id = open_operator_session
    row = {id: "row-1", body: "the operator's turn"}
    fake = FakeExecutor.new(rows: [row])
    stub_executor(fake)

    verdict = @runner.run_next(@quest_id)

    assert_equal :briefing_ran, verdict
    assert_equal 1, fake.exchanged.size
    assert_equal row, fake.exchanged.first
    assert_equal session_id, fake.session.fetch(:id)
    assert_equal 1, conn[:sessions].where(quest_id: @quest_id).count,
                 "the exchange serves the OPERATOR session — no second session"
    _ = phase_id
  end

  def test_open_operator_session_with_nothing_enqueued_holds
    conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "decompose",
                         round_no: 1, state: "pending")
    open_operator_session
    stub_executor(FakeExecutor.new(rows: []))

    assert_equal :briefing_hold, @runner.run_next(@quest_id)
  end

  def test_engine_error_from_the_exchange_is_loud_and_still_briefing_ran
    conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "decompose",
                         round_no: 1, state: "pending")
    open_operator_session
    fake = FakeExecutor.new(rows: [{id: "row-1", body: "x"}],
                            error: Kquest::Engine::Error.new("the governor banked the session"))
    stub_executor(fake)

    verdict = @runner.run_next(@quest_id)

    assert_equal :briefing_ran, verdict,
                 "the turn WAS consumed and executed; the engine's own law owned the failure"
    assert_includes @stderr.string, "BRIEFING_EXCHANGE_FAILED:", "never silent"
    assert_includes @stderr.string, "the governor banked the session"
  end

  def test_never_started_decompose_r1_with_no_session_and_no_agenda_awaits
    phase_id = conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "decompose",
                                    round_no: 1, state: "pending", started_at: nil)

    assert_equal :awaiting_briefing, @runner.run_next(@quest_id)
    assert_empty conn[:sessions].where(quest_id: @quest_id).to_a,
                 "no session launched — the gate honest (the launcher re-spawns on cadence)"
    _ = phase_id
  end

  def test_never_started_rule_is_r1_only_and_agenda_gated
    r1_id = conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "decompose",
                                 round_no: 1, state: "pending", started_at: nil)
    quest = quest_row

    # never-started decompose ROUND 2 is not the briefing's phase: runs on
    r2_id = conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "decompose",
                                 round_no: 2, state: "pending", started_at: nil)
    refute @runner.send(:never_started_briefing?, conn[:phases].where(id: r2_id).first, quest),
           "round_no == 1 is the rule's own condition"

    # never-STARTED is the rule's other condition: a started pending r1 runs
    conn[:phases].where(id: r1_id).update(started_at: Time.now)
    refute @runner.send(:never_started_briefing?, conn[:phases].where(id: r1_id).first, quest)

    # agenda staged flips the rule off (the autonomy hand-off)
    conn[:phases].where(id: r1_id).update(started_at: nil)
    OrchestratorFixtures.mint_source(conn, user_id: @user_id, quest_id: @quest_id,
                                     snapshot: "agenda bytes", role: "agenda")
    refute @runner.send(:never_started_briefing?, conn[:phases].where(id: r1_id).first, quest)

    # the rule ON: pending, started_at nil, no agenda
    conn[:quest_sources].delete
    assert @runner.send(:never_started_briefing?, conn[:phases].where(id: r1_id).first, quest)
  end

  def test_sr02_web_call_counting_includes_agenda_stage_rows
    # The extended predicate at the BOUNDARY (Grounds §4.5/§5.7, PHASE 0
    # note 1): staging-only web spend crosses the quest's web line and fires
    # the SR-02 row — the evasion the extension kills. One web_search + one
    # agenda_stage (ok) vs a 1-call budget, HARD: used=2 > 1.
    conn[:quests].where(id: @quest_id).update(web_call_budget: 1)
    web_calls(1)
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id,
                             session_id: conn[:sessions].insert(
                               user_id: @user_id, quest_id: @quest_id,
                               phase_id: conn[:phases].insert(
                                 user_id: @user_id, quest_id: @quest_id, kind: "decompose",
                                 round_no: 9
                               ), mode: "autonomous", driver: "orchestrator",
                               model: "test-model"
                             ), seq: 1, tool: "agenda_stage",
                             args: Sequel.lit("'{}'::jsonb"), result: Sequel.lit("'{}'::jsonb"),
                             ok: true)
    phase_id = complete_phase("descent", process_config:
      {"modes" => {"quest.web_call_budget" => "hard"}})

    verdict = boundary(phase_id)

    assert_equal :entered, verdict
    assert_includes @stderr.string, "PROCESS_STOP: SR-02",
                    "the staged fetch counts at the boundary (the extended predicate)"
  end
end
