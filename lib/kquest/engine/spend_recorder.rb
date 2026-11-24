# frozen_string_literal: true

module Kquest
  module Engine
    # The spend ledger's call-site recorder (I04 §9, R-046, D10): a gem
    # telemetry sink — `Client.new(telemetry: [recorder])`. The gem's
    # terminal invariant (EXACTLY ONE of `on_completion_end` XOR
    # `on_completion_error` per completion; retries INSIDE the completion)
    # makes "one row per API call, failures included" structural (FM-25);
    # this sink ASSERTS the invariant and raises on violation.
    #
    # Rows are BUFFERED at the hooks and written by `flush!` inside the
    # LoopDriver's turn transaction — same-transaction with the
    # TranscriptLedger append (I04 §9). Failure-path flushes are the
    # driver's/governor's first act before escalating: a failed call's
    # zero-token row survives the failed turn (E-SPEND — the call is still
    # an event).
    class SpendRecorder
      include Fast::Completions::Telemetry::Sink

      attr_reader :pending

      def initialize(conn:, session:, provider_row:, seed_source: -> { nil })
        @conn = conn
        @session = session
        @row = provider_row
        @seed_source = seed_source
        @pending = []
        @terminal = false
        @salvaged_usage = nil
      end

      # ── the five hook protocol ──────────────────────────────────────

      def on_completion_start(_model_id, _request_bytes)
        @terminal = false
        @salvaged_usage = nil
        nil
      end

      def on_completion_ttfb(_seconds); end

      # The salvage path's carrier: the client-level `:error` event holds the
      # partial Message (in the event's `message` field — the terminal events'
      # carrier) whose usage is the ONLY recoverable mid-turn token count
      # (FM-15).
      def on_event(event)
        partial = event.message || event.partial
        @salvaged_usage = partial.usage if event.type == :error && partial&.usage
        nil
      end

      def on_completion_end(stop_reason, _duration, message)
        open_terminal!
        record(message&.usage)
        stop_reason
      end

      def on_completion_error(_error, _duration)
        open_terminal!
        # A creation failure records a zero-token row; a salvage records the
        # salvaged partial's usage (FM-15); a nil/absent usage on a dialect
        # that cannot report it is the zero-row honesty marker (FM-25).
        record(@salvaged_usage)
      end

      # ── the buffered write ─────────────────────────────────────────

      # Writes every buffered row. Called inside the loop's turn transaction
      # (same-transaction with the ledger append) and on every failure path
      # before escalation.
      def flush!
        until @pending.empty?
          @conn[:usage_events].insert(@pending.shift)
        end
        nil
      end

      private

      # The sink's own assertion of the gem's terminal invariant: exactly one
      # terminal hook per completion. A second terminal (without an
      # intervening start) violates the spend contract — RAISE, never
      # double-record (FM-25's consumer-raise arm).
      def open_terminal!
        if @terminal
          raise Error, "usage_events terminal invariant violated: a second terminal hook fired for " \
                       "one completion (exactly one of on_completion_end XOR on_completion_error is " \
                       "the gem's contract) — refusing to double-record spend"
        end
        @terminal = true
        nil
      end

      def record(usage)
        usage ||= Fast::Completions::Usage::ZERO
        @pending << {
          user_id: @session.fetch(:user_id), quest_id: @session.fetch(:quest_id),
          phase_id: @session.fetch(:phase_id), session_id: @session.fetch(:id),
          kind: "llm",
          model: @session.fetch(:model), # sessions.model parity — never a prompt echo (E-NOECHO)
          input_tokens: usage.input, output_tokens: usage.output,
          cache_read_tokens: usage.cache_read, cache_write_tokens: usage.cache_write,
          reasoning_tokens: usage.reasoning,
          seed: @seed_source.call,
          cost_usd: cost_for(usage)
        }
        nil
      end

      # D10 cost honesty: the provider row's cost_per_mtok_* pricing; NULL
      # pricing = a local engine (NULL cost). The chain
      # session→phase→quest→user is total by construction (the row carries
      # the tenancy keys; I01 DR-13/DR-14).
      def cost_for(usage)
        return nil if @row[:cost_per_mtok_in].nil? || @row[:cost_per_mtok_out].nil?

        in_cost  = BigDecimal(usage.input.to_s)  * BigDecimal(@row[:cost_per_mtok_in].to_s)
        out_cost = BigDecimal(usage.output.to_s) * BigDecimal(@row[:cost_per_mtok_out].to_s)
        ((in_cost + out_cost) / 1_000_000).round(6)
      end
    end
  end
end
