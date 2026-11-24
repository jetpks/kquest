# frozen_string_literal: true

require "digest"

module Kquest
  module Engine
    # The turn cycle (I04 §2.2, R-039/R-040): context assembly hand-off (from
    # a PHASE CONTRACT object supplied by the CALLER — ENTRY 4/6 own real
    # contracts; half (a) callers are tests + the headless script),
    # `Chat#step` invocation, outcome classification (final+tools → next
    # turn; final empty no tools → FM-01 → the phase-attempt accounting;
    # raise → RetryGovernor via the failure-modes classes), terminal
    # conditions from the phase contract, and the turn-boundary checks
    # (budgets FM-17, pause flag FM-19, ceiling check FM-02). The turn
    # transaction: the TranscriptLedger append + the SpendRecorder rows land
    # together (I04 §9). The loop NEVER re-implements streaming, request
    # building, or tool dispatch (DR-13) — and never blocks the reactor
    # (fiber-native law).
    #
    # The phase contract duck type (caller-supplied):
    #   assemble_context(turn)  → {instructions: String, messages: [Message]}
    #   terminal?(turn:, chat:) → Boolean
    #   max_turns               → Integer
    class LoopDriver
      attr_reader :chat, :turns

      def initialize(conn:, desk:, harness:, ledger:, budgeter:, watch:, governor:,
                     supervisor:, contract:, config:, tools: [], chat: nil)
        @conn = conn
        @config = config
        @desk = desk
        @harness = harness
        @ledger = ledger
        @budgeter = budgeter
        @watch = watch
        @governor = governor
        @supervisor = supervisor
        @contract = contract
        @chat = chat || Fast::Completions::Chat.new(client: desk.client, model: desk.model)
        @harness.register!(@chat, tools: tools) # the registration IS the restriction (I05 §8)
        @turns = 0
        @result_notes = []
        @last_request_fingerprint = nil
        @last_served_seed = nil
      end

      # Observability notes (budget routes, ceiling exits, shrink records) —
      # the returned evidence; never a silent continue.
      attr_reader :result_notes

      def run
        loop do
          verdict = boundary_checks!
          return verdict if verdict != :continue

          return :terminal if @contract.terminal?(turn: @turns, chat: @chat)
          return :turn_cap if @contract.respond_to?(:max_turns) && @turns >= @contract.max_turns

          outcome = run_turn(@turns)
          @turns += 1
          return outcome if %i[budget_paused paused ceiling_ended].include?(outcome)

          # :tools_ran/:final/:empty_completion/:retrying/:context_shrunk →
          # the loop continues (fresh seed, next turn).
        end
      ensure
        @desk.close
      end

      # One turn: context assembly hand-off → `Chat#step` → classification →
      # the turn transaction (ledger append + spend rows, I04 §9).
      def run_turn(turn)
        context = @contract.assemble_context(turn)
        apply_context!(context)

        final = @chat.step { |event| @ledger.observe(event) }
        record_request_facts!
        outcome = classify(final)
        persist_turn(final: final, turn: turn, stop_reason: final.stop_reason)

        outcome == :empty_completion ? empty_completion!(turn) : outcome
      rescue Fast::Completions::CancelledError
        # FM-19: NO phantom terminal, the half-streamed turn never appended;
        # committed mutations (tool_calls rows) survive. The cancelled
        # completion's error row is still an event (E-SPEND).
        @ledger.drop_buffer!
        flush_spend!
        @supervisor.pause_quest!(user_id: @desk.session.fetch(:user_id),
                                 quest_id: @desk.session.fetch(:quest_id),
                                 note: "FM-19: pause delivered mid-turn — the in-flight turn " \
                                       "cancelled (no phantom terminal)")
        @supervisor.bank_session!(session_id: @desk.session.fetch(:id))
        :paused
      rescue Fast::Completions::Error => e
        # The failure-table path: persist the salvage/usage audit FIRST (the
        # salvage is the only recoverable mid-turn token count), then
        # classify + retry/escalate. The request facts (fingerprint/seed) are
        # recorded even on the failed step — the FM-03 guard compares the
        # attempt that JUST ran.
        record_request_facts!
        @conn.transaction do
          @ledger.flush_salvage!
          flush_spend!
        end
        handle_failure!(e)
      end

      # The outcome classification (I04 §2.2): final + tools ran → next turn;
      # final empty, no tools → FM-01 (retryable); (raises classify via the
      # governor).
      def classify(final)
        content = final.content
        return :tools_ran if content.any? { |block| block.is_a?(Hash) && block[:type] == :tool_call }

        empty_text_only = content.all? do |block|
          block.is_a?(Hash) && block[:type] == :text && block[:text].strip.empty?
        end
        return :empty_completion if content.empty? || empty_text_only

        :final
      end

      private

      # The FM-03 complement's inputs (the last request's fingerprint + seed)
      # — recorded after each step for the governor's identical-(body, seed)
      # refusal. The messages ARE the request body's variable content (the
      # sampling params are fixed); the seed is the decorator's.
      def record_request_facts!
        @last_request_fingerprint = Digest::SHA256.hexdigest(@chat.messages.map(&:to_h).to_s)
        @last_served_seed = @desk.client.last_served_seed
        nil
      end

      # E-NOECHO: the assembled context carries NO model/config identity
      # strings — identity lives in `sessions.model`/`usage_events.model`
      # only (I04 §5.5).
      def apply_context!(context)
        identity_strings = [@desk.row[:model_id], @desk.row[:base_url], @desk.row[:name]]
        haystack = [context[:instructions].to_s,
                    *context[:messages].map { |m| m.to_h.to_s }].join("\n")
        leaked = identity_strings.compact.select { |s| !s.empty? && haystack.include?(s) }
        return if leaked.empty?

        raise Error, "prompt-echo prohibition (E-NOECHO): the assembled context carries model/config " \
                     "identity string(s) #{leaked.inspect} — identity lives in sessions.model/" \
                     "usage_events.model only; fix the phase contract's assembly"
      end

      def persist_turn(final:, turn:, stop_reason:)
        @conn.transaction do
          @ledger.append_turn(final: final, turn: turn, stop_reason: stop_reason)
          @budgeter.record_transcript_bytes!(@ledger.bytes)
          flush_spend!
        end
        @watch&.observe_transcript!(@ledger.bytes)
        @watch&.observe_size_ceiling!(@ledger.bytes, warn_bytes: @desk.transcript_ceiling_warn_bytes)
        nil
      end

      def flush_spend! = @desk.spend.flush!

      # FM-01: an empty completion retries the turn with a FRESH seed (the
      # decorator's per-request injection makes this structural) inside the
      # same session, counts the phase attempt (`phases.attempt_no`), and at
      # cap banks the session + ends the phase attempt — never silent.
      def empty_completion!(_turn)
        cap = Engine.config_value(@config, "engine.phase_attempt_cap")
        phase = @conn[:phases].where(id: @desk.session.fetch(:phase_id)).first
        attempts = phase[:attempt_no].to_i + 1
        @conn[:phases].where(id: phase[:id]).update(attempt_no: attempts)
        if attempts >= cap
          @governor.bank_session!(session_id: @desk.session.fetch(:id), phase_id: phase[:id],
                                  reason: "FM-01: empty completion at the phase attempt cap (#{cap})")
          raise Error, "FM-01: empty completion exhausted the phase attempt cap (#{cap}) — " \
                       "session banked, phase attempt ended loudly (never silent)"
        end
        :empty_completion
      end

      # The turn-boundary checks: budgets (FM-17), pause flag (FM-19),
      # ceilings (FM-02). Returns :continue when the loop may proceed.
      def boundary_checks!
        @budgeter.quest_token_budget ||= @conn[:quests]
                                           .where(id: @desk.session.fetch(:quest_id))
                                           .get(:token_budget)
        if @budgeter.budget_exhausted?
          @result_notes << {route: "never-reportless-finisher",
                            note: "FM-17: the token budget rollup reached the quest cap — no new " \
                                  "turns start; the never-reportless finisher discipline is " \
                                  "ENTRY 6's (a budget stop is never silently reportless)"}
          @supervisor.pause_quest!(user_id: @desk.session.fetch(:user_id),
                                   quest_id: @desk.session.fetch(:quest_id),
                                   note: "FM-17: budget ceiling at the turn boundary")
          return :budget_paused
        end

        if @supervisor.pause_requested?(@desk.session.fetch(:quest_id))
          @supervisor.pause_quest!(user_id: @desk.session.fetch(:user_id),
                                   quest_id: @desk.session.fetch(:quest_id),
                                   note: "FM-19: pause delivered at the turn boundary " \
                                         "(in-flight turn banked)")
          @supervisor.bank_session!(session_id: @desk.session.fetch(:id))
          return :paused
        end

        case @budgeter.ceiling_band
        when :warn
          # The warn band refuses NEW ingestion (the harness's budget-guard
          # seam carries the refusal) and banks at the boundary.
          @result_notes << {ceiling: "warn",
                            note: "FM-02 warn band: no new ingestion; the session banks at the boundary"}
          @supervisor.bank_session!(session_id: @desk.session.fetch(:id))
          return :ceiling_ended
        when :hard
          menu = @budgeter.ceiling_menu_record
          @supervisor.end_at_ceiling!(session_id: @desk.session.fetch(:id),
                                      phase_id: @desk.session.fetch(:phase_id), menu_record: menu)
          @result_notes << {ceiling: "hard", menu: menu}
          return :ceiling_ended
        end

        :continue
      end

      # The failure path: the governor classifies (the failure table) and
      # executes — bounded jittered retry (the driver re-runs the turn; the
      # decorator injects the fresh seed), then bank + end the phase attempt
      # loudly (L2), pause for the operator-visible classes (L3).
      def handle_failure!(error)
        class_name = @governor.class_for(error)
        case class_name
        when :context_length
          # FM-09: shrink + re-issue ONCE (fresh seed), then bank at the
          # boundary (the FM-02 ceiling machinery is the backstop).
          verdict = @budgeter.handle_context_error!
          if verdict == :reissue_once
            @budgeter.record_shrunk!
            @result_notes << {fm: "FM-09", action: "shrink-once",
                              note: "context length exceeded — the context is compacted and the " \
                                    "turn re-issues ONCE (never the same body); a second overflow banks"}
            return :context_shrunk
          end
          @governor.bank_session!(session_id: @desk.session.fetch(:id),
                                  phase_id: @desk.session.fetch(:phase_id),
                                  reason: "FM-09: unshrinkable context overflow — banked at the boundary")
          raise Error, "FM-09: context overflow could not be shrunk — session banked at the boundary"
        when :terminal
          # FM-10/FM-26: terminal classes fail loud, NO retry; a wire-level
          # dialect rejection (FM-10) or a final 401/403/404 (FM-26) pauses
          # the quest for reconfiguration via the provider seam.
          @governor.pause_quest!(user_id: @desk.session.fetch(:user_id),
                                 quest_id: @desk.session.fetch(:quest_id),
                                 note: "terminal failure: #{error.class}: #{error.message.to_s[0, 200]}")
          raise Error, "terminal failure (no retry): #{error.class}: #{error.message}"
        else
          begin
            @governor.retry!(class_name, session: @desk.session,
                             fingerprint: @last_request_fingerprint.to_s,
                             seed: @last_served_seed)
            :retrying
          rescue Kquest::Engine::Error
            # The class cap is exhausted: bank the session (committed
            # mutations survive) and end the phase attempt loudly.
            @governor.bank_session!(session_id: @desk.session.fetch(:id),
                                    phase_id: @desk.session.fetch(:phase_id),
                                    reason: "#{class_name} retry cap exhausted (L2)")
            raise
          end
        end
      end
    end
  end
end
