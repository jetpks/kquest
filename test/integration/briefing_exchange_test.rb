# frozen_string_literal: true

require_relative "../test_helper"
require "fast/completions"
require "kernel/sync"
require_relative "../support/orchestrator_fixtures"
require_relative "../support/mock_completions_server"
require_relative "../support/mock_exa_server"
require_relative "../../lib/kquest/orchestrator/quest_worker"
require_relative "../../lib/kquest/orchestrator/phase_runner"
require_relative "../../lib/kquest/orchestrator/worker_registry"
require_relative "../../lib/kquest/engine/session_supervisor"
require_relative "../../lib/kquest/ui/operator_write"

# The keyless full-stack briefing exchange (I18 Spec Part 1.11 / AC8): the
# operator session is opened through the LANDED door (OperatorWrite), a turn
# is ENQUEUEed (a direct `briefing_turns` row — the door law is the UI
# lane's), and the QUEST WORKER consumes it and drives the agent half through
# the engine loop bound to the OPERATOR session: a scripted web_search →
# agenda_stage (the exa mock serves the fetch) → topic_questions → text
# final. Asserts the row flip, the transcript lines (operator + tool +
# final), the audited tool_calls, the role-agenda source, the merged
# `phases.result`, the usage_events spend rows, and then BOTH sign-off tails:
# with agenda staged the next worker tick runs decompose autonomously (the
# hand-off); without agenda the worker returns :awaiting_briefing (honest).
# The I13 injected-sink pattern reads the transcript back (the MemorySink is
# per-instance in test — Grounds §4.3).
class BriefingExchangeTest < Minitest::Test
  PAGE = {"url" => "https://example.test/briefing-primer",
          "title" => "The briefing primer",
          "text" => "The momentum decay horizon is measurable out of sample."}.freeze

  class VerdictSpy < SimpleDelegator
    attr_reader :verdicts

    def initialize(runner)
      super
      @verdicts = []
    end

    def run_next(quest_id)
      verdict = __getobj__.run_next(quest_id)
      @verdicts << verdict
      verdict
    end
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @completions = MockCompletionsServer.new.start
    @exa = MockExaServer.new.start
    @prefix = OrchestratorFixtures.redis_prefix
    @redis = OrchestratorFixtures.redis_client

    # The injected sink (the I13 pattern): every ledger this test's worker
    # builds appends into ONE shared sink — the read-back seam. (Captured in
    # a local: define_method's closure binds the local, not the singleton's
    # ivar space.)
    @shared_sink = Kquest::Engine::TranscriptLedger::MemorySink.new
    shared_sink = @shared_sink
    Kquest::Engine::TranscriptLedger.singleton_class.alias_method(:i18_original_build_sink,
                                                                  :build_sink)
    Kquest::Engine::TranscriptLedger.singleton_class.define_method(:build_sink) { shared_sink }

    mint_config_rows
  end

  def teardown
    Kquest::Engine::TranscriptLedger.singleton_class.alias_method(:build_sink,
                                                                  :i18_original_build_sink)
    Kquest::Engine::TranscriptLedger.singleton_class.remove_method(:i18_original_build_sink)
    @completions&.stop
    @exa&.stop
    Sync { @registry&.unregister! }
    Sync { OrchestratorFixtures.cleanup_redis(@redis, @prefix) } if @redis
    @redis&.close
    OrchestratorFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  # Config data (the standing law: tests upsert their own; the seeds re-heal
  # at the next prepare).
  def mint_config_rows
    {
      "phase_task_text.briefing" =>
        "Converse with the operator to decompose the top-level question.",
      "phase_task_text.decompose" =>
        "Take one or more corpus sources with no evidence nodes yet: extract " \
        "verbatim-anchored evidence and claim nodes and seed the frontier.",
      "phase_task_text.synthesis" =>
        "Write the report FROM THE GRAPH.",
      "tools.web_provider" => nil
    }.each do |key, text|
      conn[:tool_config].where(key: key).delete
      if text
        conn[:tool_config].insert(key: key, text_value: text,
                                  provenance: "test-minted config data")
      end
    end
  end

  def mint_quest_with_machinery(state: "active", topic: "the briefing quest")
    conn[:llm_providers].where(name: "briefing-provider").delete
    conn[:llm_providers].insert(name: "briefing-provider", base_url: @completions.url,
                                api_key_ref: nil, model_id: "briefing-model",
                                context_window: 8192, max_tokens: 512, reasoning: false,
                                max_retries: 0)
    conn[:web_providers].where(name: "briefing-exa").delete
    conn[:web_providers].insert(name: "briefing-exa", base_url: @exa.url, api_key_ref: nil,
                                params: Sequel.lit("'{}'::jsonb"))
    conn[:tool_config].where(key: "tools.web_provider").delete
    conn[:tool_config].insert(key: "tools.web_provider", text_value: "briefing-exa",
                              provenance: "test-minted config data")
    model_config = %w[decompose frontier-build descent synthesis verification]
                   .map { |kind| [kind, "briefing-provider"] }.to_h
    tenancy = OrchestratorFixtures.mint_tenancy(conn, state: state, topic: topic,
                                                web_call_budget: 16,
                                                token_budget: 5_000_000,
                                                spend_budget_usd: 5.0,
                                                process_config: {"quest.frontier_build_max" => 0,
                                                                 "quest.frontier_floor_mass" => 200},
                                                model_config: model_config)
    @user_id = tenancy.fetch(:user_id)
    tenancy.fetch(:quest_id)
  end

  def worker_for(quest_id)
    @registry ||= Kquest::Orchestrator::WorkerRegistry.new(redis: @redis, kind: "quest",
                                                           quest_id: quest_id, prefix: @prefix)
    supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn, liveness: @registry)
    publisher = Kquest::Orchestrator::EventPublisher.new(redis: @redis, prefix: @prefix)
    watcher = Kquest::Orchestrator::TranscriptWatcher.new(
      quest_id: quest_id, publisher: publisher, config: Kquest::Engine.config(conn)
    )
    projector = Kquest::Orchestrator::LedgerProjector.new(conn: conn, publisher: publisher)
    runner = VerdictSpy.new(Kquest::Orchestrator::PhaseRunner.new(
                              conn: conn, supervisor: supervisor, publisher: publisher,
                              registry: @registry, watcher: watcher
                            ))
    @spy = runner
    Kquest::Orchestrator::QuestWorker.new(conn: conn, quest_id: quest_id, registry: @registry,
                                          supervisor: supervisor, runner: runner,
                                          watcher: watcher, projector: projector,
                                          sleeper: ->(_s) {})
  end

  def await!(what, limit: 400)
    deadline = limit
    until yield
      deadline -= 1
      raise Minitest::Assertion, "timed out waiting for #{what}" if deadline.zero?

      sleep 0.05
    end
  end

  # ── the full-stack exchange + the autonomy hand-off ────────────────────

  def test_the_keyless_exchange_and_both_signoff_tails
    quest_id = mint_quest_with_machinery
    user = conn[:users].where(id: @user_id).first

    Sync do
      # The LANDED open door (the seizure; mode interactive, driver operator,
      # the decompose round-1 mint).
      session = Kquest::Ui::OperatorWrite.open_session!(conn, user: {id: user.fetch(:id),
                                                                     username: user.fetch(:username)},
                                                        quest: conn[:quests].where(id: quest_id).first)
      @session_id = session.fetch(:id)

      # ENQUEUE (a direct row — the write door is the UI lane's).
      conn[:briefing_turns].insert(user_id: @user_id, quest_id: quest_id,
                                   session_id: @session_id, seq: 1,
                                   body: "search for a momentum-decay primer, stage it, " \
                                         "and write our two questions")

      @completions.script([
        {type: :tool_use, tool_calls: [{id: "ix1", name: "web_search",
                                        arguments: {query: "momentum decay primer"}}]},
        {type: :tool_use, tool_calls: [{id: "ix2", name: "agenda_stage",
                                        arguments: {url: PAGE.fetch("url"),
                                                    title: PAGE.fetch("title")}}]},
        {type: :tool_use, tool_calls: [{id: "ix3", name: "topic_questions",
                                        arguments: {questions: ["What is the decay horizon?",
                                                                "How fast does it decay?"],
                                                    topic: "Momentum decay"}}]},
        {type: :text, content: "Staged the primer and recorded two questions — refine anything?"},
        {type: :text, content: "the scripted decompose attempt is complete"},
        {type: :text, content: "the scripted synthesis attempt is complete"}
      ])
      @exa.script([
        {type: :results, results: [PAGE]}, # the search
        {type: :results, results: [PAGE]}  # the staging fetch (contents)
      ])

      # The WORKER (the §8 loop law: the agent half of the chat). The
      # controller signs off once the exchange is durable; the worker's next
      # tick takes the autonomy hand-off; the arc ends at the loud
      # P-NOREPORT pause (no standing report — the never-reportless law),
      # which exits the worker.
      worker = worker_for(quest_id)
      worker_task = Async { worker.run }

      await!("the exchange to consume the turn") do
        conn[:briefing_turns].where(session_id: @session_id).get(:state) == "consumed"
      end
      await!("the exchange to land the questions carrier") do
        text = conn[:phases].where(quest_id: quest_id, kind: "decompose", round_no: 1)
                            .get(Sequel.lit("result::text"))
        text && JSON.parse(text).key?("topic_questions")
      end

      # ── the exchange's durable receipts ─────────────────────────────────
      row = conn[:briefing_turns].where(session_id: @session_id).first
      assert_equal "consumed", row.fetch(:state)
      refute_nil row.fetch(:consumed_at)

      tools = conn[:tool_calls].where(session_id: @session_id).order(:seq).select_map(:tool)
      assert_equal %w[web_search agenda_stage topic_questions], tools
      assert conn[:tool_calls].where(session_id: @session_id).to_a.all? { |r| r[:ok] },
             "the audited tool_calls (session-attributed, ok=true)"

      source = conn[:sources].where(role: "agenda").first
      refute_nil source, "the role-agenda source exists (content-addressed)"
      assert source.fetch(:urn).start_with?("kb:src:")
      assert_equal conn[:quests].where(id: quest_id).get(:topic), "Momentum decay"

      assert_operator conn[:usage_events].where(quest_id: quest_id).count, :>=, 4,
                      "the spend ledger rows landed (D10)"

      blob = @shared_sink.read("sessions/#{@session_id}/transcript.jsonl")
      refute_nil blob, "the transcript blob carries the exchange"
      lines = blob.split("\n").filter_map { |l| JSON.parse(l) rescue nil }
      assert_equal "operator", lines.first["type"]
      assert_includes lines.first["body"], "search for a momentum-decay primer"
      assert_equal 3, lines.count { |l| l["type"] == "tool_result" }
      final = lines.reverse.find { |l| l["type"] == "final" }
      assert_includes final.dig("message", "content", 0, "text"), "Staged the primer"

      # ── the sign-off + the autonomy hand-off ────────────────────────────
      Kquest::Ui::OperatorWrite.end_session!(conn, quest_id: quest_id)
      refute_nil conn[:sessions].where(id: @session_id).get(:ended_at), "the sign-off ends"

      await!("the decompose phase to run autonomously to completion") do
        conn[:phases].where(quest_id: quest_id, kind: "decompose", round_no: 1)
                     .get(:state) == "complete"
      end
      # The arc's honest end: decompose's boundary advances per the table
      # (the frontier rounds exhausted → not fb_eligible, nothing open →
      # synthesis); the synthesis boundary with no standing report is the
      # loud fallback pause — the worker exits on its own law.
      verdict = worker_task.wait
      assert_equal :paused, verdict
      assert_equal "paused", conn[:quests].where(id: quest_id).get(:state)

      assert_includes @spy.verdicts, :briefing_ran, "the worker served the queue"
      assert @spy.verdicts.any? { |v| v == :entered },
             "the autonomy hand-off entered the next phase (the transition table)"
      assert_includes @spy.verdicts, :briefing_hold,
                      "the worker held while the operator session was open"
      decompose = conn[:phases].where(quest_id: quest_id, kind: "decompose", round_no: 1).first
      refute_nil decompose.fetch(:started_at), "the autonomous attempt STARTED the phase"
      refute_nil conn[:phases].where(quest_id: quest_id, kind: "synthesis").first,
                 "the boundary advanced per the transition table"
    end
  end

  # ── the no-agenda twin (the honest sign-off tail) ──────────────────────

  def test_signoff_without_staged_agenda_leaves_the_worker_awaiting_briefing
    quest_id = mint_quest_with_machinery
    user = conn[:users].where(id: @user_id).first

    Sync do
      Kquest::Ui::OperatorWrite.open_session!(conn,
                                              user: {id: user.fetch(:id),
                                                     username: user.fetch(:username)},
                                              quest: conn[:quests].where(id: quest_id).first)
      Kquest::Ui::OperatorWrite.end_session!(conn, quest_id: quest_id)

      # No agenda staged, no open operator session, decompose r1 pending and
      # never started → the worker waits honestly and exits on the verdict.
      verdict = worker_for(quest_id).run

      assert_equal :awaiting_briefing, verdict
      assert_empty conn[:sessions].where(quest_id: quest_id, ended_at: nil).to_a,
                   "no session launched — the gate is honest, not guessed"
    end
  end
end
