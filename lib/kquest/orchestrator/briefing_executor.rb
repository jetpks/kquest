# frozen_string_literal: true

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
require_relative "briefing_contract"

module Kquest
  module Orchestrator
    # The briefing exchange executor (I18 the §8 amendment; Spec Part 1.6):
    # the AGENT's half of the chat. Operator turns ENQUEUE (a durable
    # `briefing_turns` row — the web process stays LLM-free); the WORKER
    # consumes the oldest enqueued row and drives the engine loop THROUGH the
    # OPERATOR session — never a second session (the write gate is already
    # held; L13), with the FOUR-tool briefing registration (the registration
    # IS the restriction), the BriefingContract's four-part assembly, and the
    # per-turn `after_turn:` seam (the worker wires its periodic passes —
    # reaper/projector/watcher — for per-turn SSE visibility without a second
    # thread, Grounds §4.4).
    #
    # The queue row is the turn's RECEIPT, not a retry flag: it stays
    # `consumed` in every error shape. Error shapes ride the engine's own
    # laws (FM-01/02/17/19, the RetryGovernor, E-NOECHO — no new failure
    # machinery); the governor's loud path banks the session and raises, the
    # executor releases its claims and lets the raise through (the runner's
    # briefing branch owns the catch — the run_phase_attempt precedent).
    class BriefingExecutor
      # The briefing's registered surface (Spec Part 1.6 — four tools; the
      # registration IS the restriction, I05 §8).
      BRIEFING_SURFACE = %w[web_search web_fetch agenda_stage topic_questions].freeze

      def initialize(conn:, supervisor:, registry: nil, watcher: nil, publisher: nil,
                     after_turn: nil, contract_factory: nil, stderr: $stderr)
        @conn = conn
        @supervisor = supervisor
        @registry = registry
        @watcher = watcher
        @publisher = publisher
        @after_turn = after_turn
        @contract_factory = contract_factory || ->(args) { BriefingContract.new(**args) }
        @stderr = stderr
      end

      # ── the queue halves (the runner composes them) ─────────────────────

      # The OLDEST `enqueued` row for the session (ORDER BY seq) flipped
      # `consumed` (consumed_at now) in one transaction — the turn's durable
      # receipt. Returns the row (a Hash) or nil when none is enqueued
      # (the runner maps that to `:briefing_hold`).
      def consume_next!(quest:, session:)
        row = @conn[:briefing_turns]
              .where(session_id: session.fetch(:id), state: "enqueued")
              .order(:seq).first
        return nil unless row

        @conn.transaction do
          flipped = @conn[:briefing_turns]
                    .where(id: row.fetch(:id), state: "enqueued")
                    .update(state: "consumed", consumed_at: Time.now)
          raise Kquest::Engine::Error,
                "briefing turn #{row.fetch(:id)} was consumed concurrently — the queue's " \
                "per-session seq is single-consumer (the worker loop is single-threaded)" unless flipped == 1
        end
        row
      end

      # The exchange: append the operator line (the transcript's operator
      # turns enter the audit where the agent's turns do — the WORKER writes
      # the blob, never the web), build the conversation + machinery bound to
      # the OPERATOR session, and drive the LoopDriver until the contract's
      # terminal (a content-bearing text-only completion) or the engine's own
      # boundary/ceiling/failure laws end the loop. Verdict mapping:
      # :terminal/:turn_cap → :completed; :budget_paused/:paused/
      # :ceiling_ended → themselves (the engine already acted —
      # pause-and-present); a Kquest::Engine::Error rides the governor's loud
      # path through (released claims in an ensure; the row stays consumed).
      def exchange!(quest:, session:, row:)
        tenancy = tenancy_for(session)
        ledger = Kquest::Engine::TranscriptLedger.new(conn: @conn, session: tenancy)
        ledger.append_operator!(body: row.fetch(:body))

        phase = @conn[:phases].where(id: tenancy.fetch(:phase_id)).first
        unless phase
          raise Kquest::Engine::Error,
                "the operator session #{tenancy.fetch(:id)} has no binding phase row — the " \
                "briefing exchange cannot assemble (the binding decompose round-1 phase is the " \
                "questions carrier; open the session through the briefing door)"
        end

        config = read_config(quest)
        provider_row = resolve_provider(quest, tenancy)
        desk = Kquest::Engine::ProviderDesk.new(conn: @conn, provider_row: provider_row,
                                                session: tenancy)
        @watcher&.register_ledger(tenancy.fetch(:id), ledger)
        budgeter = Kquest::Engine::ContextBudgeter.new(conn: @conn, session: tenancy, desk: desk,
                                                       config: config.fetch(:engine))
        watch = Kquest::Engine::StreamWatch.new(conn: @conn, session: tenancy,
                                                config: config.fetch(:engine))
        governor = Kquest::Engine::RetryGovernor.new(conn: @conn, config: config.fetch(:engine),
                                                     supervisor: @supervisor,
                                                     sleeper: ->(s) { sleep s })
        tools = Kquest::Tools.registry(BRIEFING_SURFACE, conn: @conn, session: tenancy,
                                        ledger: ledger, config: config.fetch(:tools))
        harness = Kquest::Engine::ToolHarness.new(conn: @conn, session: tenancy, ledger: ledger,
                                                  config: config.fetch(:engine),
                                                  write_guard: @supervisor.write_guard_for(tenancy),
                                                  budgeter: budgeter)
        contract = @contract_factory.call(conn: @conn, quest: quest, phase: phase,
                                          session: tenancy, config: config, ledger: ledger)
        chat = build_chat(desk, contract)
        driver = BriefingDriver.new(after_turn: @after_turn,
                                    conn: @conn, desk: desk, harness: harness, ledger: ledger,
                                    budgeter: budgeter, watch: watch, governor: governor,
                                    supervisor: @supervisor, contract: contract,
                                    config: config.fetch(:engine), tools: tools, chat: chat)
        claim!(tenancy.fetch(:id))
        classify(driver.run)
      ensure
        release_claims!(tenancy && tenancy.fetch(:id))
        @watcher&.release_ledger(tenancy.fetch(:id)) if tenancy
      end

      private

      # The exchange's driver: the frozen LoopDriver + the per-turn seam —
      # after_turn fires after EVERY exchange turn whose run_turn returns
      # (the turn's ledger/spend transaction is committed at that point; a
      # cancelled/raised turn fires nothing — FM-19 keeps the no-phantom law).
      class BriefingDriver < Kquest::Engine::LoopDriver
        def initialize(after_turn: nil, **kwargs)
          @briefing_after_turn = after_turn
          super(**kwargs)
        end

        def run_turn(turn)
          outcome = super(turn)
          @briefing_after_turn&.call
          outcome
        end
      end

      # The engine tenancy hash from the open operator session ROW (the same
      # shape drive_session/ProviderDesk/Ledger consume).
      def tenancy_for(session)
        {id: session.fetch(:id), user_id: session.fetch(:user_id),
         quest_id: session.fetch(:quest_id), phase_id: session.fetch(:phase_id),
         model: session.fetch(:model), driver: session.fetch(:driver)}
      end

      # Claim the OPERATOR session into liveness for the exchange (the
      # in-process Set — OperatorWrite's reuse shape — plus the registry port,
      # the runner's shape): the harness's write-guard recheck sees the gate
      # HELD BY THIS SESSION for the duration; released in exchange!'s ensure.
      # NEVER bank_session! — the operator session is held BY ITS ROW until
      # sign-off (Grounds §4.1; DR-04 ruling A).
      def claim!(session_id)
        @supervisor.live_sessions << session_id
        @registry&.claim_session!(session_id)
        nil
      end

      def release_claims!(session_id)
        return unless session_id

        @supervisor.live_sessions.delete(session_id)
        @registry&.release_session!(session_id)
        nil
      end

      def build_chat(desk, contract)
        context = contract.assemble_context(0)
        chat = Fast::Completions::Chat.new(client: desk.client, model: desk.model)
        chat.with_instructions(context[:instructions]) if context[:instructions]
        Array(context[:messages]).each { |m| chat.add_message(m) }
        chat
      end

      def classify(verdict)
        case verdict
        when :budget_paused, :paused, :ceiling_ended then verdict
        else :completed
        end
      end

      # The provider resolution (Spec Part 1.6): sessions.model →
      # model_config["decompose"] → the sole provider row → the loud resolve
      # refusal (phase_runner.rb#resolve_provider's fallback shape).
      def resolve_provider(quest, tenancy)
        model_config = quest.fetch(:model_config)
        model_config = JSON.parse(model_config) if model_config.is_a?(String)
        model_config ||= {}
        row = @conn[:llm_providers].where(name: tenancy.fetch(:model).to_s).first
        decompose = model_config["decompose"]
        row ||= decompose && @conn[:llm_providers].where(name: decompose.to_s).first
        row || @conn[:llm_providers].first ||
          raise(Kquest::Engine::Error,
                "no llm_providers row is available for the briefing exchange (session model " \
                "#{tenancy.fetch(:model).inspect}, model_config['decompose'] " \
                "#{decompose.inspect}) — provider rows are operator/session-minted config (the " \
                "standing law); mint one before opening the briefing")
      end

      # The FULL live config re-read (P-REREAD, I06 §6.2 — phase_runner.rb's
      # own shape, mirrored): global defaults ⊕ quests.process_config ⊕
      # quests.model_config ⊕ the stop rules.
      def read_config(quest)
        process = quest.fetch(:process_config)
        process = JSON.parse(process) if process.is_a?(String)
        model_config = quest.fetch(:model_config)
        model_config = JSON.parse(model_config) if model_config.is_a?(String)
        {
          engine: Kquest::Engine.config(@conn),
          tools: Kquest::Tools.config(@conn),
          process: process || {},
          model_config: model_config || {},
          stop_rules: @conn[:stop_rules].order(:rule_id).to_a
        }
      end
    end
  end
end
