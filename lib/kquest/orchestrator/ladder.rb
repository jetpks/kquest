# frozen_string_literal: true

require "digest"
require "securerandom"
require "stringio"
require_relative "../engine"
require_relative "../engine/session_supervisor"
require_relative "../engine/loop_driver"
require_relative "../engine/provider_desk"
require_relative "../engine/transcript_ledger"
require_relative "../engine/context_budgeter"
require_relative "../engine/stream_watch"
require_relative "../engine/retry_governor"
require_relative "../engine/tool_harness"
require_relative "../tools"
require_relative "../queries/status_snapshot"
require_relative "event_publisher"

module Kquest
  module Orchestrator
    # The model-qualification ladder (I07 §7; I08 §10): every rung mints its
    # scenario, runs its work through the REAL engine + REAL tools (never a
    # fake tool surface — the BRIEF §9 pattern: the mock IS the wire), and
    # evaluates its gate per the §7 table. On PASS it writes ONE
    # `ladder_passes` row (the landed DDL: model, rung, serving_stack,
    # passed_at, evidence_ref, passed_by — evidence_ref = the transcript/
    # session/ledger ids + the rung result; passed_by = the operator identity
    # arg). The routing rule stays REVIEWABLE, never machine-checked (I07
    # DR-06: no FK, no enforcement — the rows are evidence the routing-map
    # editor cites).
    #
    # KEYLESS LAW: without `--live` (and its key), a rung runs against the
    # in-process mock wires and is a MACHINERY proof; the live leg requires
    # the named key path and LOUD-SKIPS keyless (never a silent pass, never
    # fabricated numbers).
    class Ladder
      RUNGS = %w[probe smoke partial full].freeze

      # The R-018 metabolism constants the partial rung bands against.
      METABOLISM = {evidence_per_source: 5.0, claims_per_source: 2.6}.freeze

      attr_reader :conn, :mocks, :evidence

      def initialize(conn:, passed_by: "ladder-runner")
        @conn = conn
        @passed_by = passed_by
        @mocks = []
        @evidence = {}
      end

      # The live leg: without the key path the rung LOUD-SKIPS (exit
      # 0-with-skip marker — the recalibration pattern).
      def self.live_key_missing?(key_path)
        key_path.nil? || key_path.to_s.empty? || !File.file?(key_path.to_s)
      end

      # ── rung: probe ─────────────────────────────────────────────────────

      # Sandbox probe on a fixed topic: one web search → fetch-with-save →
      # an anchored node write → a paragraph whose [^1] resolves. PASS =
      # usable first tool call + artifacts written + the citation resolves.
      def probe
        rig = build_rig("the Antikythera mechanism's gear train models the lunar cycle")
        begin
          session_id = drive_scripted_session(rig, PROBE_SCRIPT)
          gate_probe!(session_id)
          record_pass!(rung: "probe", session_id: session_id)
        ensure
          teardown_rig(rig)
        end
      end

      # ── rung: smoke ─────────────────────────────────────────────────────

      # One decompose phase on a fresh topic: every staged source mined ≥1
      # evidence, no graph_invalid loop, context peak under window.
      def smoke
        rig = build_rig(nil, corpus: true)
        begin
          session_id = drive_scripted_session(rig, DECOMPOSE_SCRIPT)
          gate_smoke!(rig[:quest_id], session_id)
          record_pass!(rung: "smoke", session_id: session_id)
        ensure
          teardown_rig(rig)
        end
      end

      # ── rung: partial ───────────────────────────────────────────────────

      # decompose + boundary discipline: three zeros at every boundary,
      # refusal_rate under a set ceiling, churn/shape/repetition tripwires
      # quiet, metabolism within band of the R-018 constants.
      def partial
        rig = build_rig(nil, corpus: true)
        begin
          session_id = drive_scripted_session(rig, DECOMPOSE_SCRIPT)
          gate_partial!(rig[:quest_id], session_id)
          record_pass!(rung: "partial", session_id: session_id)
        ensure
          teardown_rig(rig)
        end
      end

      # The full rung rides the scripted-quest machinery (Part 11) — the
      # complete arc IS the full-quest gate's subject; its evidence_ref is
      # the PASS row the scripted quest wrote (the arc's own record).
      def full
        require File.expand_path("../../../script/scripted_quest_run", __dir__)
        ScriptedQuest.run(passed_by: @passed_by, ladder: true)
        row = conn[:ladder_passes].where(rung: "full")
                                  .order(Sequel.desc(:passed_at)).first
        row ? row.fetch(:evidence_ref) : "rung=full"
      end

      # ── the machinery ───────────────────────────────────────────────────

      # The mock rig: completions + exa wires in-process, the local registry
      # model, the provider row — the headless_engine_run pattern, scaled.
      def build_rig(web_topic, corpus: false)
        root = File.expand_path("../../..", __dir__)
        require File.join(root, "test/support/mock_completions_server")
        require File.join(root, "test/support/mock_embeddings_server")
        require File.join(root, "test/support/mock_exa_server")
        require File.join(root, "test/support/pipeline_fixtures")

        completions = MockCompletionsServer.new.start
        embeddings = MockEmbeddingsServer.new.start
        exa = MockExaServer.new.start
        @mocks = [completions, embeddings, exa]
        conn[:llm_providers].where(name: "ladder-provider").delete
        conn[:llm_providers].insert(name: "ladder-provider", base_url: completions.url,
                                    api_key_ref: nil, model_id: "ladder-model",
                                    context_window: 8192, max_tokens: 512, reasoning: false,
                                    max_retries: 0)
        provider_row = conn[:llm_providers].where(name: "ladder-provider").first
        # The embed model points at the EMBEDDINGS mock — never the
        # completions mock: node_add's probe-vector embed call rides the
        # embeddings wire, and a wrong endpoint there would consume a
        # completions script spec per call (the tool_calls queue shifts).
        PipelineFixtures.register_test_model(conn, embeddings)
        # Script the embeddings mock with real-dimension vectors: its
        # script-less default is a 1-dim [0.0] reply, and node_add's dedup
        # near-leg feeds it into <=> against the 384-dim CHECK table — a
        # dim-mismatch DataException inside the harness transaction that
        # the failure-isolation rescue swallows while the aborted
        # transaction kills the tool_calls/evidence writes (the
        # order-dependent suite flake, judge-root-caused at integration).
        # 384-dim zeros are the pipeline tests' own landed pattern; one spec
        # per potential embed call, a deep queue for any rung.
        embeddings.script(Array.new(512) { {type: :embeddings,
                                            vectors: [[0.0] + Array.new(PipelineFixtures::MINILM_DIMS - 1, 0.0)],
                                            usage: {prompt_tokens: 1, total_tokens: 1}} })
        set_tool_config("tools.claim_embedding_model", PipelineFixtures::MINILM_MODEL_ID)

        user_id = conn[:users].insert(handle: "gh-#{SecureRandom.hex(6)}",
                                      github_uid: SecureRandom.uuid,
                                      username: "u#{SecureRandom.hex(6)}",
                                      name: "Ladder Fixture", created_at: Time.now)
        quest_id = conn[:quests].insert(user_id: user_id, topic: web_topic || "ladder fixture topic",
                                        web_call_budget: 16, token_budget: 1_000_000,
                                        spend_budget_usd: 1.0)
        # The probe drafts + binds a report — `report_versions` ' composite FK
        # (synthesis_phase_id, quest_id, synthesis_phase_kind) → phases(id,
        # quest_id, kind) with the landed 'synthesis' default — so the probe's
        # sandbox phase row is synthesis-kind. The corpus rungs only mine
        # (node_add) and keep the decompose kind.
        phase_kind = corpus ? "decompose" : "synthesis"
        phase_id = conn[:phases].insert(user_id: user_id, quest_id: quest_id, kind: phase_kind)
        sources = []
        if corpus
          sources << OrchestratorFixtures.mint_source(
            conn, user_id: user_id, quest_id: quest_id,
            snapshot: "The ladder fixture corpus: momentum profits persist after controlling " \
                      "for market beta; the fixture literature documents the spread; screening " \
                      "precedes the weighting step; transaction costs erode the raw premium; " \
                      "out-of-sample decay is measurable."
          )
        end
        conn[:web_providers].where(name: "ladder-exa").delete
        conn[:web_providers].insert(name: "ladder-exa", base_url: exa.url, api_key_ref: nil,
                                    params: Sequel.lit("'{}'::jsonb"))
        set_tool_config("tools.web_provider", "ladder-exa")
        @evidence_quest_id = quest_id
        {conn: conn, completions: completions, embeddings: embeddings, exa: exa,
         provider_row: provider_row,
         user_id: user_id, quest_id: quest_id, phase_id: phase_id, sources: sources}
      end

      def teardown_rig(rig)
        @mocks.each(&:stop)
        @mocks = []
        OrchestratorFixtures.cleanup(conn, user_id: rig[:user_id]) if rig[:user_id]
        nil
      end

      # One scripted phase attempt through the REAL engine (the headless
      # pattern): the gate, the loop, the bank — the tools are the registered
      # surface, the wire is the in-process mock.
      def drive_scripted_session(rig, script)
        rig[:completions].script(script)
        if rig[:sources].empty?
          # The probe's fetch-with-save: the wire serves one search + one page.
          page = {"url" => "https://example.test/antikythera",
                  "title" => "The Antikythera mechanism",
                  "text" => "The gear train models the lunar cycle with striking precision."}
          rig[:exa].script([{type: :results, results: [page]},
                            {type: :results, results: [page]}])
        end
        supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn)
        session_id = supervisor.launch(user_id: rig[:user_id], quest_id: rig[:quest_id],
                                       phase_id: rig[:phase_id], mode: "autonomous",
                                       driver: "orchestrator",
                                       model: rig[:provider_row][:model_id])
        session = {id: session_id, user_id: rig[:user_id], quest_id: rig[:quest_id],
                   phase_id: rig[:phase_id], model: rig[:provider_row][:model_id]}
        config = Kquest::Engine.config(conn)
        desk = Kquest::Engine::ProviderDesk.new(conn: conn, provider_row: rig[:provider_row],
                                                session: session)
        ledger = Kquest::Engine::TranscriptLedger.new(conn: conn, session: session)
        budgeter = Kquest::Engine::ContextBudgeter.new(conn: conn, session: session, desk: desk,
                                                       config: config)
        watch = Kquest::Engine::StreamWatch.new(conn: conn, session: session, config: config)
        governor = Kquest::Engine::RetryGovernor.new(conn: conn, config: config,
                                                     supervisor: supervisor,
                                                     sleeper: ->(s) { sleep s })
        tools = Kquest::Tools.registry(OPERATOR_SURFACE, conn: conn, session: session,
                                       ledger: ledger, config: Kquest::Tools.config(conn))
        harness = Kquest::Engine::ToolHarness.new(conn: conn, session: session, ledger: ledger,
                                                  config: config,
                                                  write_guard: supervisor.write_guard_for(session),
                                                  budgeter: budgeter)
        contract = Object.new
        contract.define_singleton_method(:assemble_context) { |_turn|
          {instructions: "the ladder rung's scripted phase", messages: []}
        }
        contract.define_singleton_method(:terminal?) { |turn:, chat:|
          chat.complete? && turn >= 1
        }
        contract.define_singleton_method(:max_turns) { 12 }
        driver = Kquest::Engine::LoopDriver.new(conn: conn, desk: desk, harness: harness,
                                                ledger: ledger, budgeter: budgeter, watch: watch,
                                                governor: governor, supervisor: supervisor,
                                                contract: contract, config: config, tools: tools)
        driver.run
        supervisor.bank_session!(session_id: session_id)
        @evidence[session_id] = {transcript_bytes: ledger.bytes, turns: driver.turns}
        session_id
      end

      # The day-one registered surface (the operator profile's tools minus
      # the subagent pair the rungs never spawn).
      OPERATOR_SURFACE = %w[
        node_add node_set node_get edge_add frontier_add frontier_close
        status search list paths mass neighbors
        source_read source_grep source_list
        web_search web_fetch
        retrieve
        report_draft report_bind
        quest_status
      ].freeze

      # ── the rung gates (I07 §7's table) ─────────────────────────────────

      def gate_probe!(session_id)
        first_call = conn[:tool_calls].where(session_id: session_id).order(:seq).first
        raise GateFailure, "no usable first tool call" unless first_call&.fetch(:ok)

        versions = conn[:report_versions].where(quest_id: @evidence_quest_id)
        raise GateFailure, "no report artifact written" unless versions.count.positive?
        raise GateFailure, "the paragraph's [^1] does not resolve" unless citations_bound?(versions.first)
      end

      def gate_smoke!(quest_id, session_id)
        remaining = conn[:v_unmined_sources].where(quest_id: quest_id).count
        raise GateFailure, "staged sources mined < 1 evidence each (#{remaining} unmined)" if remaining.positive?

        zeros = Kquest::Queries::StatusSnapshot.new(conn: conn)
                    .status_fields(user_id: rig_user(quest_id), quest_id: quest_id)
        raise GateFailure, "GRAPH_INVALID shape at the boundary (the three zeros)" if
          zeros[:bare_claims].positive? || zeros[:unreferenced].positive? ||
          zeros[:dual_arm_claims].positive?

        peak = @evidence.fetch(session_id).fetch(:transcript_bytes)
        window = conn[:llm_providers].where(name: "ladder-provider").get(:context_window)
        raise GateFailure, "context peak #{peak} over the window #{window}" if peak >= window
      end

      def gate_partial!(quest_id, session_id)
        gate_smoke!(quest_id, session_id)
        calls = conn[:tool_calls].where(quest_id: quest_id).count
        refusals = conn[:tool_calls].where(quest_id: quest_id, ok: false).count
        rate = calls.zero? ? 0.0 : refusals.to_f / calls
        raise GateFailure, "refusal_rate_session #{rate} over the ceiling 0.5" if rate > 0.5

        sources = conn[:quest_sources].where(quest_id: quest_id).count
        evidence = conn[:evidence].where(quest_id: quest_id).count
        return if sources.zero?

        ratio = evidence.to_f / sources
        band = METABOLISM.fetch(:evidence_per_source)
        raise GateFailure, "metabolism evidence_per_source #{ratio} outside the R-018 band " \
                           "(#{band * 0.5}..#{band * 2})" if ratio < band * 0.5 || ratio > band * 2
      end

      def citations_bound?(version)
        conn[:report_citations].where(report_version_id: version.fetch(:id)).count.positive?
      end

      def rig_user(quest_id)
        conn[:quests].where(id: quest_id).get(:user_id)
      end

      class GateFailure < StandardError; end

      # The PASS record (I08 §10's landed DDL; the routing rule stays
      # reviewable — this row is EVIDENCE, never enforcement).
      def record_pass!(rung:, session_id:)
        model = conn[:llm_providers].where(name: "ladder-provider").get(:model_id) || "ladder-model"

        quest_id = @evidence_quest_id
        evidence_ref = "rung=#{rung} session=#{session_id} quest=#{quest_id} " \
                       "turns=#{@evidence.dig(session_id, :turns)} " \
                       "transcript_bytes=#{@evidence.dig(session_id, :transcript_bytes)}"
        conn[:ladder_passes].insert(id: SecureRandom.uuid,
                                    model: model, rung: rung, serving_stack: "in-process mock wires",
                                    passed_at: Time.now, evidence_ref: evidence_ref,
                                    passed_by: @passed_by)
        evidence_ref
      end

      def set_tool_config(key, text)
        conn[:tool_config].where(key: key).delete
        conn[:tool_config].insert(key: key, text_value: text,
                                  provenance: "ladder test-minted config data")
        nil
      end

      # ── the rung scripts (the mock IS the wire) ─────────────────────────

      PROBE_SCRIPT = [
        {type: :tool_use, tool_calls: [{id: "ladder-1", name: "web_search",
                                        arguments: {query: "Antikythera mechanism gear train"}}]},
        {type: :tool_use, tool_calls: [{id: "ladder-2", name: "web_fetch",
                                        arguments: {url: "https://example.test/antikythera"}}]},
        {type: :tool_use, tool_calls: [{id: "ladder-3", name: "node_add",
                                        arguments: {label: "evidence",
                                                    src: "C1",
                                                    span: "The gear train models the lunar cycle",
                                                    reading: "the gear train models the lunar cycle",
                                                    supports_new: [{"text": "the Antikythera gear " \
                                                                            "train models the lunar cycle"}]}}]},
        {type: :tool_use, tool_calls: [{id: "ladder-4", name: "report_draft",
                                        arguments: {section: "Findings",
                                                    body: "The mechanism's gear train models the " \
                                                          "lunar cycle. [^1]"}}]},
        {type: :tool_use, tool_calls: [{id: "ladder-5", name: "report_bind", arguments: {}}]},
        {type: :text, content: "the probe rung's scripted work is complete"}
      ].freeze

      # The smoke/partial decompose script: five fused node_add calls mine
      # the staged fixture source (evidence per source lands inside the
      # R-018 band for the partial gate; each fused claim carries a typed
      # terminal so the three zeros hold at the boundary).
      DECOMPOSE_SCRIPT = [
        {type: :tool_use, tool_calls: [{id: "ladder-s1", name: "node_add",
                                        arguments: {label: "evidence", src: "C1",
                                                    span: "momentum profits persist after controlling",
                                                    reading: "momentum persists after beta control",
                                                    supports_new: [{"text" => "momentum profits persist "                                                                             "after controlling for "                                                                             "market beta",
                                                                    "terminal" => {"type" => "primary-empirical",
                                                                                   "basis" => "the fixture " \
                                                                                              "corpus"}}]}}]},
        {type: :tool_use, tool_calls: [{id: "ladder-s2", name: "node_add",
                                        arguments: {label: "evidence", src: "C1",
                                                    span: "the fixture literature documents the spread",
                                                    reading: "the literature documents the spread",
                                                    supports_new: [{"text" => "the spread is documented "                                                                             "in the fixture literature",
                                                                    "terminal" => {"type" => "primary-empirical",
                                                                                   "basis" => "the fixture " \
                                                                                              "corpus"}}]}}]},
        {type: :tool_use, tool_calls: [{id: "ladder-s3", name: "node_add",
                                        arguments: {label: "evidence", src: "C1",
                                                    span: "screening precedes the weighting step",
                                                    reading: "screening precedes weighting",
                                                    supports_new: [{"text" => "screening precedes the "                                                                             "weighting step",
                                                                    "terminal" => {"type" => "definitional-mathematical",
                                                                                   "basis" => "the fixture " \
                                                                                              "corpus"}}]}}]},
        {type: :tool_use, tool_calls: [{id: "ladder-s4", name: "node_add",
                                        arguments: {label: "evidence", src: "C1",
                                                    span: "transaction costs erode the raw premium",
                                                    reading: "costs erode the premium",
                                                    supports_new: [{"text" => "transaction costs erode "                                                                             "the raw premium",
                                                                    "terminal" => {"type" => "primary-empirical",
                                                                                   "basis" => "the fixture " \
                                                                                              "corpus"}}]}}]},
        {type: :tool_use, tool_calls: [{id: "ladder-s5", name: "node_add",
                                        arguments: {label: "evidence", src: "C1",
                                                    span: "out-of-sample decay is measurable",
                                                    reading: "decay is measurable out of sample",
                                                    supports_new: [{"text" => "out-of-sample decay is "                                                                             "measurable",
                                                                    "terminal" => {"type" => "primary-empirical",
                                                                                   "basis" => "the fixture " \
                                                                                              "corpus"}}]}}]},
        {type: :text, content: "the staged source is mined; the rung's work is complete"}
      ].freeze
    end
  end
end
