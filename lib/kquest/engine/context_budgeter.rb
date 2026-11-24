# frozen_string_literal: true

require "json"

module Kquest
  module Engine
    # Per-session context accounting (I04 §7, R-040/R-042): tool-result
    # ingestion bytes (the harness reports sizes), cumulative token accounting
    # from usage rows (L10: budgets read the ledger, never stored counters),
    # transcript-size tracking (feeds StreamWatch), the sliced-read cap
    # accounting (`engine.read_slice_cap_chars` — advisory lines TEACH, hard
    # lines change behavior at the boundary; the read-tool refusal itself is
    # I14's), the FM-09 shrink-once-then-bank path, the FM-24 prefix-cache
    # wall (the prompt prefix stays APPEND-ONLY within a session; alert on
    # cache_read = 0 at high context), and the FM-02 ceiling bands. Every
    # line is {scope, value, mode} advisory-by-default, toggleable to hard
    # (DR-09 as ruled) — hard lines enforce at TURN BOUNDARIES, advisory
    # lines teach, never silent truncation.
    class ContextBudgeter
      attr_reader :ingested_bytes, :transcript_bytes

      def initialize(conn:, session:, desk:, config:)
        @conn = conn
        @session = session
        @desk = desk
        @config = config
        @ingested_bytes = 0
        @transcript_bytes = 0
        @quest_token_budget = nil
        @shrunk = false
        @alerts = []
        @last_cache_read = nil
      end

      attr_reader :alerts

      # ── accounting ─────────────────────────────────────────────────────

      # The harness reports every tool result's size (the ingestion economy —
      # the 78% lesson's accounting half).
      def record_ingestion!(result)
        size = result.is_a?(String) ? result.bytesize : JSON.generate(result).bytesize
        @ingested_bytes += size
        size
      end

      # Transcript growth (the ledger reports; StreamWatch consumes).
      def record_transcript_bytes!(bytes)
        @transcript_bytes = bytes
        bytes
      end

      # Cumulative token accounting FROM THE LEDGER (L10 — a crash can never
      # strand a stale counter): the rollup over this session's usage_events.
      def token_rollup
        @conn[:usage_events]
          .where(session_id: @session.fetch(:id), kind: "llm")
          .sum(Sequel.lit("input_tokens + output_tokens + cache_read_tokens + cache_write_tokens"))
          .to_i
      end

      # ── FM-02: the size-ceiling bands (per-provider, DR-06) ────────────

      def ceiling_band
        hard = @desk.transcript_ceiling_hard_bytes
        warn = @desk.transcript_ceiling_warn_bytes
        return :hard if @transcript_bytes >= hard
        return :warn if @transcript_bytes >= warn

        :ok
      end

      # The warn band refuses NEW ingestion (never a mid-flight transcript
      # truncation — L8 audit integrity); the harness's budget-guard seam
      # calls this before every tool execution.
      def tool_budget_check!(_tool_name)
        band = ceiling_band
        return if band == :ok

        raise Error, "FM-02 #{band} ceiling band: new ingestion is refused — the session banks at " \
                     "the boundary; narrow the request or wait for the operator (DR-06: never " \
                     "truncate a live transcript mid-flight)"
      end

      # The hard band ends the session at the boundary — SessionSupervisor
      # records the DR-06 menu (A swap-at-the-wall, B compact-and-continue).
      def ceiling_menu_record
        {ceiling: "hard", transcript_bytes: @transcript_bytes,
         options: ["A swap-at-the-wall", "B compact-and-continue"],
         rule: "DR-06: the RUNTIME OPERATOR DECIDES — never truncate a live transcript mid-flight"}
      end

      # ── FM-17: the budget ceiling (the turn-boundary rollup) ───────────

      def budget_exhausted?
        return false if @quest_token_budget.nil?

        token_rollup >= @quest_token_budget
      end

      attr_accessor :quest_token_budget
      # ── FM-22: the sliced-read cap (advisory teaches, hard changes
      #    behavior; the read-tool refusal is I14's) ──────────────────────

      def account_read!(chars)
        cap = Engine.config_value(@config, "engine.read_slice_cap_chars")
        line = @config.fetch("engine.read_slice_cap_chars")
        return {verdict: :ok} if chars <= cap

        note = "READ-SLICE: #{chars} chars exceeds read_slice_cap_chars (#{cap}) — slice the read " \
               "(offset/limit form); front-loading corpus text is the 78% context-blowout lesson"
        if line.fetch(:mode) == "hard"
          {verdict: :refused, note: note}
        else
          {verdict: :marked, note: note}
        end
      end

      # ── FM-09: shrink-once-then-bank ───────────────────────────────────

      # ContextLengthExceededError NEVER retries the same body: shrink the
      # context (compact) and re-issue ONCE; unshrinkable → bank at the
      # boundary (the FM-02 ceiling machinery is the backstop).
      def handle_context_error!
        return :reissue_once unless @shrunk

        :bank
      end

      def record_shrunk!
        @shrunk = true
        nil
      end

      # ── FM-24: the prefix-cache wall ───────────────────────────────────

      # The prompt prefix within a session stays APPEND-ONLY (stable prefix =
      # cache hits). A shrinking prefix is a cache-wall defect — loud, never
      # silent.
      def ensure_append_only!(previous_messages, new_messages)
        return if previous_messages.nil? || previous_messages.empty?

        short = [previous_messages.size, new_messages.size].min
        short.times do |i|
          old = previous_messages[i].to_h
          new = new_messages[i].to_h
          next if old == new

          raise Error, "prompt prefix is not append-only at message #{i} (FM-24 cache-wall law): " \
                       "within a session the prefix never shrinks or rewrites — stable prefix = " \
                       "cache hits"
        end
        nil
      end

      # cache_read = 0 at high context = every turn pays a full re-prefill
      # (the ~205k wall). Alert only — the routing fix is ENTRY 6's.
      def observe_usage!(input_tokens:, cache_read_tokens:)
        @last_cache_read = cache_read_tokens
        wall = @desk.cache_wall_tokens
        return if wall.nil? || wall.zero?

        return unless input_tokens >= wall && cache_read_tokens.zero?

        @alerts << {type: "cache_wall",
                    message: "CACHE-WALL: cache_read = 0 at #{input_tokens} input tokens (wall " \
                             "#{wall}) — every turn pays a full re-prefill; keep the prompt prefix " \
                             "append-only and route mega-context phases per the routing config (FM-24)"}
        nil
      end
    end
  end
end
