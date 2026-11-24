#!/usr/bin/env ruby
# frozen_string_literal: true

# The SCRIPTED QUEST (I15 Part 11 — the named observable): ONE quest walks
# briefing-init → decompose → frontier-build → descent → synthesis →
# verification → quest-done with EVERY step taken by EVALUATING the seeded
# `phase_transitions` / `stop_rules` tables (the runner is a pure config
# consumer — nothing here encodes a transition). Standalone (like
# script/headless_engine_run.rb); runs HANAMI_ENV=test; KEYLESS — its OWN
# in-process Mock{Completions,Embeddings,Exa}Server rigs ARE the wires; its
# own redis keys live under a unique test prefix and are cleaned.
#
# The PINNED scenario (seeded fixture corpus — 2 citable sources with
# snapshot blobs, 1 agenda source; budgets small; `quests.process_config`
# pins `quest.max_phases` low and the web line HARD so the stop fires
# deterministically):
#   1. briefing-init (no phases row) with the agenda source staged → row 10
#      (agenda_staged → decompose, autonomy-handoff).
#   2. decompose: scripted fused node_add calls mine both citable sources
#      (real tools, real write-time validation) with thin frontier seeding;
#      the boundary: three zeros + v_decompose_remaining = 0 + fb_eligible →
#      frontier-build (mass-floor-gate, the loud FRONTIER_BUILD line).
#   3. frontier-build: a scripted frontier_add call takes mass over the
#      floor → descent.
#   4. descent: scripted closures (frontier_close + derives_from wiring + a
#      typed terminal); at the boundary the HARD web line crosses (scripted
#      web_search/web_fetch calls counted at the tool) → the budget_exhausted
#      row fires → route-to-synthesis with the full loud shape.
#   5. synthesis: scripted report_draft + report_bind (citation coverage
#      holds) — but the STILL-crossed web line re-fires at the finisher
#      boundary (`any-finisher-phase budget_exhausted → paused`,
#      pause-and-present — the tables' own row 6). The config law's steering
#      channel exists for exactly this disposition (I06 §6.2: "Config
#      CHANGES land only through pause … the PoC's own WEB_BUDGET_RAISE
#      behavior (a cap may only RAISE on resume) is the steering-channel
#      precedent"): the operator resumes with the cap RAISED.
#   6. verification: the Part 10 machinery runs (Q1V zero on the fixture
#      graph; the sampler draws with a recorded seed) → verification_clean →
#      quest-done (the ledgered `complete` lifecycle event).
#   Mid-quest (during the decompose attempt's first, deliberately slow
#   turn), a SECOND concurrent launch attempt (operator-mode, racing the
#   gate) is REFUSED naming the holder — SECOND_WRITER_REFUSED.
#
# The script SELF-VERIFIES against durable state (phases rows in table
# order; the lifecycle event chain; the stop marker in the synthesis prompt
# assembly; the SSE backlog event catalog — key-filtered), then prints the
# marker block. Any failing check prints SCRIPTED_QUEST_FAILED <check>
# (rc 1). Callers running inside their own Sync reactor (the ladder's full
# rung) call ScriptedQuest.run directly.

require "bundler/setup"
require "hanami/prepare"
require "fast/completions"
require "kernel/sync"
require "json"
require_relative "../test/support/mock_completions_server"
require_relative "../test/support/mock_embeddings_server"
require_relative "../test/support/mock_exa_server"
require_relative "../test/support/pipeline_fixtures"
require_relative "../test/support/orchestrator_fixtures"

# The fixture corpus (the snapshots the scripted spans must be byte-present
# in — real write-time validation, L1).
SNAP1 = "Fixture corpus source one: the screening precedes the weighting " \
        "step, and transaction costs erode the raw premium once the spread " \
        "is charged."
SNAP2 = "Fixture corpus source two: momentum profits persist after " \
        "controlling for market beta, and the out-of-sample decay is " \
        "measurable."
AGENDA = "Fixture agenda source: the staged agenda for the scripted quest."
SPAN1 = "the screening precedes the weighting step"
SPAN2 = "momentum profits persist after controlling for market beta"

SCRIPT_PAGE = {"url" => "https://example.test/fixture-decay",
               "title" => "The fixture decay study",
               "text" => "The momentum decay horizon is measurable out of sample."}

# The whole-arc completions script (the mock IS the wire). ONE spec per
# chat turn, consumed in order across every phase attempt; the leading
# :slow_ttfb widens the launch-gate race window (it answers as an empty
# completion — the FM-01 retry consumes the NEXT spec, by design).
ARC_SCRIPT = [
  {type: :slow_ttfb, delay: 1.0}, # decompose t1: the race window (→ FM-01 retry)
  {type: :tool_use, tool_calls: [{id: "sq-1", name: "node_add",
                                  arguments: {label: "evidence", src: "C1", span: SPAN1,
                                              reading: "screening precedes weighting",
                                              supports_new: [{"text" => "screening precedes " \
                                                                        "the weighting step",
                                                              "terminal" => {"type" => "primary-empirical",
                                                                             "basis" => "fixture " \
                                                                                        "corpus " \
                                                                                        "source one"}}]}}]},
  {type: :tool_use, tool_calls: [{id: "sq-2", name: "node_add",
                                  arguments: {label: "evidence", src: "C2", span: SPAN2,
                                              reading: "momentum persists after beta control",
                                              supports_new: [{"text" => "momentum profits persist " \
                                                                        "after controlling for " \
                                                                        "market beta",
                                                              "terminal" => {"type" => "primary-empirical",
                                                                             "basis" => "fixture " \
                                                                                        "corpus " \
                                                                                        "source two"}}]}}]},
  {type: :tool_use, tool_calls: [{id: "sq-3", name: "frontier_add",
                                  arguments: {claim: "K1", need: "Fixture 2024, the " \
                                                                     "screening-weighting " \
                                                                     "ordering study",
                                              uncertainty: 2, relevance: 1}}]},
  {type: :text, content: "the decompose phase's scripted work is complete"},
  {type: :tool_use, tool_calls: [{id: "sq-4", name: "frontier_add",
                                  arguments: {claim: "K2", need: "Fixture 2019, the momentum " \
                                                                     "decay horizon study",
                                              uncertainty: 5, relevance: 5}}]},
  {type: :text, content: "the frontier-build phase's scripted work is complete"},
  {type: :tool_use, tool_calls: [{id: "sq-5", name: "frontier_close",
                                  arguments: {claim: "K1", closure_type: "internal"}}]},
  {type: :tool_use, tool_calls: [{id: "sq-6", name: "frontier_close",
                                  arguments: {claim: "K2", closure_type: "internal"}}]},
  {type: :tool_use, tool_calls: [{id: "sq-6a", name: "node_set",
                                  arguments: {node: "K2",
                                              fields: {"terminal" => nil}}}]},
  {type: :tool_use, tool_calls: [{id: "sq-7", name: "edge_add",
                                  arguments: {from: "K2", type: "derives_from", to: "K1"}}]},
  {type: :tool_use, tool_calls: [{id: "sq-8", name: "web_search",
                                  arguments: {query: "momentum decay horizon study fixture"}}]},
  {type: :tool_use, tool_calls: [{id: "sq-9", name: "web_fetch",
                                  arguments: {url: SCRIPT_PAGE.fetch("url")}}]},
  {type: :text, content: "the descent phase's scripted work is complete"},
  {type: :tool_use, tool_calls: [{id: "sq-10", name: "report_draft",
                                  arguments: {section: "Findings",
                                              body: "The fixture corpus holds: the screening " \
                                                    "precedes the weighting step [^1], and " \
                                                    "momentum profits persist after controlling " \
                                                    "for market beta [^2]."}}]},
  {type: :tool_use, tool_calls: [{id: "sq-11", name: "report_bind", arguments: {}}]},
  {type: :text, content: "the synthesis phase's scripted work is complete"},
  {type: :text, content: "the verification phase's scripted session completes; " \
                         "the machinery runs at the boundary"}
].freeze

EXA_SCRIPT = [
  {type: :results, results: [SCRIPT_PAGE]}, # the descent web_search
  {type: :results, results: [SCRIPT_PAGE]}  # the descent web_fetch (contents)
].freeze

module ScriptedQuest
  Result = Struct.new(:quest_id, :phase_kinds, :transitions_fired, :session_ids,
                      keyword_init: true)

  module_function

  def fail!(check)
    puts "SCRIPTED_QUEST_FAILED #{check}"
    exit 1
  end

  def run(passed_by: "scripted-quest-runner", ladder: false)
    conn = Kquest::App["db.gateway"].connection
    redis = Kquest::App["redis"]
    prefix = "kquest:sq:#{SecureRandom.hex(6)}" # unique test namespace, cleaned below
    mocks = []
    user_id = nil
    registry = nil

    completions = MockCompletionsServer.new.start
    embeddings = MockEmbeddingsServer.new.start
    exa = MockExaServer.new.start
    mocks = [completions, embeddings, exa]

    # ── the rig: provider + registry rows (config data — never seeded) ────
    conn[:llm_providers].where(name: "scripted-quest-provider").delete
    conn[:llm_providers].insert(name: "scripted-quest-provider", base_url: completions.url,
                                api_key_ref: nil, model_id: "scripted-quest-model",
                                context_window: 8192, max_tokens: 512, reasoning: false,
                                max_retries: 0)
    model_config = %w[decompose frontier-build descent synthesis verification]
                   .map { |kind| [kind, "scripted-quest-provider"] }.to_h
    set_tool_config(conn, "tools.claim_embedding_model", PipelineFixtures::MINILM_MODEL_ID)
    PipelineFixtures.register_test_model(conn, embeddings)
    conn[:web_providers].where(name: "scripted-exa").delete
    conn[:web_providers].insert(name: "scripted-exa", base_url: exa.url, api_key_ref: nil,
                                params: Sequel.lit("'{}'::jsonb"))
    set_tool_config(conn, "tools.web_provider", "scripted-exa")

    # ── the tenancy + the pinned budgets (L9: the columns ARE the values) ─
    tenancy = OrchestratorFixtures.mint_tenancy(
      conn, topic: "the scripted quest", state: "active",
      web_call_budget: 1, token_budget: 5_000_000, spend_budget_usd: 5.0,
      process_config: {
        "quest.max_phases" => 8,
        "quest.frontier_floor_mass" => 20,
        "modes" => {"quest.web_call_budget" => "hard"}
      },
      model_config: model_config
    )
    user_id = tenancy.fetch(:user_id)
    quest_id = tenancy.fetch(:quest_id)

    # ── the fixture corpus: 2 citable + 1 agenda source ───────────────────
    OrchestratorFixtures.mint_source(conn, user_id: user_id, quest_id: quest_id,
                                     snapshot: SNAP1, title: "Fixture source one")
    OrchestratorFixtures.mint_source(conn, user_id: user_id, quest_id: quest_id,
                                     snapshot: SNAP2, title: "Fixture source two")
    OrchestratorFixtures.mint_source(conn, user_id: user_id, quest_id: quest_id,
                                     snapshot: AGENDA, role: "agenda",
                                     title: "Fixture agenda")

    # ── the worker-host wiring (the bin/quest-worker.rb shape) ────────────
    registry = Kquest::Orchestrator::WorkerRegistry.new(redis: redis, kind: "quest",
                                                        quest_id: quest_id, prefix: prefix)
    registry.register!
    supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn, liveness: registry)
    publisher = Kquest::Orchestrator::EventPublisher.new(redis: redis, prefix: prefix)
    watcher = Kquest::Orchestrator::TranscriptWatcher.new(
      quest_id: quest_id, publisher: publisher, config: Kquest::Engine.config(conn)
    )
    projector = Kquest::Orchestrator::LedgerProjector.new(conn: conn, publisher: publisher)
    reaper = Kquest::Orchestrator::Reaper.new(conn: conn, liveness: registry)
    poller = Kquest::Orchestrator::AssurancePoller.new(conn: conn, publisher: publisher)
    loud = []
    stderr_collector = Object.new
    stderr_collector.define_singleton_method(:puts) do |line|
      loud << line.to_s
      $stderr.puts(line) # the loud shape stays on the worker's stderr channel
    end
    runner = Kquest::Orchestrator::PhaseRunner.new(conn: conn, supervisor: supervisor,
                                                   publisher: publisher, registry: registry,
                                                   watcher: watcher, stderr: stderr_collector)

    session_ids = []
    race_error = nil
    transitions_fired = 0
    begin
      completions.script(ARC_SCRIPT)
      exa.script(EXA_SCRIPT)

      # Step 1: the briefing-init evaluation (no phases row yet) — row 10.
      verdict = host_pass!(runner, conn, quest_id, reaper, projector, watcher, poller,
                           session_ids)
      fail!("briefing_init_agenda_staged") unless verdict == :entered
      transitions_fired += 1
      decompose_phase = conn[:phases].where(quest_id: quest_id).order(:created_at).first
      fail!("decompose_phase_row") unless decompose_phase

      # The launch-gate RACE: a second writer (operator-mode) competes for
      # the gate while the decompose attempt's first (deliberately slow)
      # turn is streaming — the FOR UPDATE serialization refuses it.
      task = Async::Task.current
      race = task.async do
        conn2 = Sequel.connect(ENV.fetch("DATABASE_URL", "postgres:///kquest_test"))
        race_registry = Kquest::Orchestrator::WorkerRegistry.new(redis: redis, kind: "operator",
                                                                quest_id: quest_id,
                                                                prefix: prefix)
        begin
          race_supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn2,
                                                                  liveness: race_registry)
          40.times do
            sleep 0.05
            begin
              race_supervisor.launch(user_id: user_id, quest_id: quest_id,
                                     phase_id: decompose_phase.fetch(:id),
                                     mode: "interactive", driver: "operator",
                                     model: "scripted-quest-model")
              race_error = "SECOND-WRITER-LEAKED: the racing launch was NOT refused"
              break
            rescue Kquest::Engine::Error => e
              race_error = e.message
              break
            end
          end
        ensure
          race_registry&.unregister!
          conn2.disconnect
        end
      end

      # Steps 2–6: the runner loop (the quest worker's host loop) — every
      # verdict the tables produce, until the quest is done. The pause-resume
      # cycle is BOUNDED (the arc has exactly one dispositioned pause; a
      # second pause without a new phase is a loop, and a loop is loud).
      resumes = 0
      loop do
        verdict = host_pass!(runner, conn, quest_id, reaper, projector, watcher, poller,
                             session_ids)
        case verdict
        when :entered, :ran
          resumes = 0
          transitions_fired += 1
        when :quest_done
          transitions_fired += 1
          break
        when :paused
          # The tables' own finisher-boundary pause (row 6): the operator
          # disposes it — resume with the cap RAISED (I06 §6.2's
          # WEB_BUDGET_RAISE steering precedent; P-REREAD lands it at the
          # next attempt boundary).
          transitions_fired += 1
          resumes += 1
          fail!("runner_pause_loop") if resumes > 2
          conn.transaction do
            conn[:quests].where(id: quest_id).for_update.first
            conn[:quests].where(id: quest_id).update(state: "active", web_call_budget: 10)
            conn[:quest_lifecycle_events].insert(
              user_id: user_id, quest_id: quest_id, from_state: "paused",
              to_state: "active", actor: "operator", occurred_at: Time.now,
              note: "the operator resumes with the web budget RAISED on resume " \
                    "(the WEB_BUDGET_RAISE steering precedent — a cap may only " \
                    "raise on resume, I06 §6.2)"
            )
          end
        else
          fail!("runner_verdict_#{verdict}")
        end
      end
      race.wait

      # ── the self-verification against DURABLE state ─────────────────────
      verify!(conn, quest_id: quest_id, completions: completions, publisher: publisher,
              prefix: prefix, redis: redis, loud: loud, race_error: race_error,
              transitions_fired: transitions_fired)

      if ladder
        conn[:ladder_passes].insert(
          id: SecureRandom.uuid, model: "scripted-quest-model", rung: "full",
          serving_stack: "in-process mock wires",
          passed_at: Time.now,
          evidence_ref: "rung=full quest=#{quest_id} sessions=#{session_ids.join(',')} " \
                        "transitions=#{transitions_fired} lifecycle=complete",
          passed_by: passed_by
        )
      end
      Result.new(quest_id: quest_id, phase_kinds: phase_kinds(conn, quest_id),
                 transitions_fired: transitions_fired, session_ids: session_ids)
    ensure
      registry&.unregister!
      mocks.each(&:stop)
      OrchestratorFixtures.cleanup(conn, user_id: user_id)
      cleanup_redis(redis, prefix)
    end
  end

  # One worker-host pass: the runner step + the periodic duties (the reaper,
  # the projector, the watcher census, the poller).
  def host_pass!(runner, conn, quest_id, reaper, projector, watcher, poller, session_ids)
    verdict = runner.run_next(quest_id)
    session_ids.concat(
      conn[:sessions].where(quest_id: quest_id).select_map(:id) - session_ids
    )
    reaper.sweep(quest_id: quest_id)
    projector.project(quest_id)
    watcher.census
    poller.pass
    verdict
  end

  # ── the checks (each its own named check — loud, never silent) ─────────

  def verify!(conn, quest_id:, completions:, publisher:, prefix:, redis:, loud:,
              race_error:, transitions_fired:)
    quest = conn[:quests].where(id: quest_id).first
    fail!("quest_state") unless quest && quest.fetch(:state) == "complete"

    # QUEST_LIFECYCLE: the ledgered chain ends at complete.
    lifecycle = conn[:quest_lifecycle_events].where(quest_id: quest_id)
                                             .order(:occurred_at).select_map(:to_state)
    fail!("quest_lifecycle") unless lifecycle.last == "complete"
    transitions = conn[:quest_lifecycle_events]
                  .where(quest_id: quest_id, to_state: "complete").count
    fail!("quest_lifecycle") unless transitions == 1

    # Phases rows in table order: the walk briefing-init→…→quest-done.
    kinds = phase_kinds(conn, quest_id)
    fail!("phase_walk") unless kinds == %w[decompose frontier-build descent synthesis verification]
    fail!("phase_states") unless conn[:phases].where(quest_id: quest_id)
                                               .where(state: "complete").count == 5

    # STOP_FIRED: the descent phase's result marker — the HARD web line.
    descent = conn[:phases].where(quest_id: quest_id, kind: "descent").first
    result_text = conn[:phases].where(id: descent.fetch(:id)).get(Sequel.lit("result::text"))
    stop = JSON.parse(result_text)["stop"]
    fail!("stop_marker") unless stop && stop.fetch("rule_id") == "SR-02" &&
                               stop.fetch("reason").include?("quest.web_call_budget") &&
                               stop.fetch("route") == "route-to-synthesis"
    fail!("loud_stderr") unless loud.any? { |l| l.include?("PROCESS_STOP: SR-02") &&
                                            l.include?("route-to-synthesis") }

    # The stop marker carried into the SYNTHESIS PROMPT (part 4 of the
    # assembly ships on the wire — the runner applies the contract's
    # turn-0 assembly to the chat it hands the LoopDriver).
    logs = completions.captured_request_logs
    marker_on_wire = logs.any? do |entry|
      messages = Array(entry.dig(:body, "messages"))
      messages.any? { |m| m["content"].to_s.include?("STOP MARKERS: PROCESS_STOP: SR-02") }
    end
    fail!("stop_marker_in_synthesis_prompt") unless marker_on_wire

    # SECOND_WRITER_REFUSED: the refusal names the holder session + driver.
    fail!("second_writer_refused") unless race_error&.include?("WRITE-GUARD") &&
                                          race_error.include?("orchestrator") &&
                                          holder_named?(race_error, conn, quest_id)

    # NEVER_REPORTLESS: the standing report version is bound and cited.
    standing = conn[:report_versions].where(quest_id: quest_id, standing: true).first
    fail!("standing_report") unless standing && standing.fetch(:bound_at)
    citations = conn[:report_citations].where(report_version_id: standing.fetch(:id)).count
    fail!("report_citations") unless citations >= 2

    # SPOT_CHECK_SEED: the verification phase's result carries the seed + ids.
    verification = conn[:phases].where(quest_id: quest_id, kind: "verification").first
    result = JSON.parse(conn[:phases].where(id: verification.fetch(:id))
                                     .get(Sequel.lit("result::text")))
    spot = result.fetch("verification", {}).fetch("spot_check", {})
    fail!("spot_check_seed") unless spot["seed"] && Array(spot["sampled_ids"]).any?
    fail!("q1v_zero") unless result.fetch("verification").fetch("q1v_dangling").empty?
    fail!("verification_clean") unless result.fetch("verification").fetch("clean") == true

    # SSE_EVENT_TYPES: the backlog's catalog — key-filtered (our prefix).
    entries = redis.call("XRANGE", publisher.quest_key(quest_id), "-", "+")
    types = entries.map do |entry|
      fields = entry[1]
      fields[fields.index("type") + 1]
    end.uniq.sort
    required = %w[quest.state phase.state session.state tool.event spend.tick
                  frontier.mass quest.stop assurance_alert]
    missing = required - types
    fail!("sse_backlog_missing:#{missing.join(',')}") unless missing.empty?

    # TRANSITIONS_EVALUATED: 7 table firings — rows 10, 12, 17, 5 (the
    # descent HARD crossing), 6 (the finisher re-cross pause), 25 (on the
    # resume) and 26 (quest-done).
    fail!("transitions_evaluated") unless transitions_fired == 7

    # The marker block.
    puts "TRANSITIONS_EVALUATED #{transitions_fired}"
    puts "STOP_FIRED quest.web_call_budget"
    puts "SECOND_WRITER_REFUSED"
    puts "SPOT_CHECK_SEED #{spot['seed']}"
    puts "SSE_EVENT_TYPES #{types.join(',')}"
    puts "QUEST_LIFECYCLE #{lifecycle.last}"
    puts "NEVER_REPORTLESS holds"
    puts "SCRIPTED_QUEST_OK"
    nil
  end

  def holder_named?(race_error, conn, quest_id)
    holder = conn[:sessions].where(quest_id: quest_id).order(:created_at).first
    holder && race_error.include?(holder.fetch(:id).to_s)
  end

  def phase_kinds(conn, quest_id)
    conn[:phases].where(quest_id: quest_id).order(:created_at).select_map(:kind)
  end

  def set_tool_config(conn, key, text)
    conn[:tool_config].where(key: key).delete
    conn[:tool_config].insert(key: key, text_value: text,
                              provenance: "scripted-quest test-minted config data")
    nil
  end

  def cleanup_redis(redis, prefix)
    pattern = "#{prefix}*"
    cursor = "0"
    loop do
      cursor, keys = redis.call("SCAN", cursor, "MATCH", pattern, "COUNT", 200)
      redis.call("DEL", *keys) unless keys.empty?
      break if cursor == "0" || cursor.to_i.zero?
    end
    nil
  end
end

if __FILE__ == $PROGRAM_NAME
  Sync do
    ScriptedQuest.run
  end
end
