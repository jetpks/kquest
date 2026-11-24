# frozen_string_literal: true

module Kquest
  module Engine
    # Consumes telemetry + transcript growth (I04 §2.1, R-045): SLOWSTALL
    # (FM-18 — ALERT ONLY, the alert text carries the driver-NOT-to-be-killed-
    # on-this-alone rule; the unattended window elapsing → pause, never
    # kill), dropped-chunk counts (FM-14 — recorded per session, alert at
    # threshold, never re-add strictness the gem removed), SIZE-CEILING early
    # warning (FM-02's warn band), repetition/empty-completion storm signals
    # (recorded counts — the TRIPWIRE PREDICATES over them are ENTRY 4/I07's,
    # never implemented here). Signals land in the observability struct
    # (`signals`) consumed by tests/the headless script; a durable signal
    # table is ENTRY 4's call, recorded as the seam.
    class StreamWatch
      include Fast::Completions::Telemetry::Sink

      SLOWSTALL_ALERT_RULE = "the driver is NOT to be killed on this signal alone"

      attr_reader :signals

      def initialize(conn:, session:, config:, pause_callback: nil)
        @conn = conn
        @session = session
        @config = config
        @pause_callback = pause_callback # the pause, never a kill (FM-18)
        @signals = []
        @transcript_samples = []         # [{at:, bytes:}]
        @last_growth_at = Time.now
        @dropped_chunks = 0
        @dropped_alerted = false
        @empty_completions = 0
        @repetition_count = 0
        @paused_on_unattended = false
      end

      # ── the telemetry hooks (a second sink on the session's client) ────

      def on_completion_start(_model_id, _request_bytes); end

      def on_completion_ttfb(_seconds); end

      def on_event(_event); end

      # Empty-completion/repetition storm inputs (recorded COUNTS only — the
      # predicates over them are ENTRY 4/I07's).
      def on_completion_end(stop_reason, _duration, message)
        if stop_reason == :stop && message && message.content.empty?
          @empty_completions += 1
          signal(:empty_completion_storm, "#{@empty_completions} empty completions recorded " \
                                          "(count only — the tripwire predicate is ENTRY 4/I07's)")
        end
        nil
      end

      def on_completion_error(_error, _duration); end

      # ── transcript growth (the ledger/driver report per turn) ──────────

      def observe_transcript!(bytes, at: Time.now)
        @transcript_samples << {at: at, bytes: bytes}
        check_slow_stall!(at)
        check_unattended!(at)
        nil
      end

      # SIZE-CEILING early warning (FM-02's warn band — the budgeter owns the
      # band logic; the watch carries the early-warning signal).
      def observe_size_ceiling!(transcript_bytes, warn_bytes:)
        return unless warn_bytes.positive? && transcript_bytes >= warn_bytes

        signal(:size_ceiling, "transcript at #{transcript_bytes}B crossed the provider's warn " \
                              "ceiling (#{warn_bytes}B) — new ingestion is refused and the session " \
                              "banks at the next boundary (FM-02)")
        nil
      end

      # FM-14: dropped chunks are the GEM's tolerance (drop-and-count, never
      # raised) — the loop records the count per session and alerts at
      # threshold; it never fails a turn for a chunk the gem tolerated.
      def observe_client!(client)
        dropped = client.dropped_chunks
        return if dropped.zero?

        # The client's count resets per stream; the SESSION's count accumulates
        # (the driver observes once per turn).
        @dropped_chunks += dropped
        threshold = Engine.config_value(@config, "engine.dropped_chunk_alert_threshold")
        return unless @dropped_chunks >= threshold && !@dropped_alerted

        @dropped_alerted = true
        signal(:dropped_chunks, "#{dropped} dropped wire chunks recorded (threshold " \
                                "#{threshold}) — a serving-stack health signal; the stream " \
                                "continues to its natural terminal (residual risks: a dropped " \
                                "finish lands in FM-13, a lost fragment in FM-11)")
        nil
      end

      def dropped_chunks = @dropped_chunks
      def empty_completions = @empty_completions

      def signal(type, message)
        @signals << {type: type, message: message, at: Time.now.utc.iso8601}
        nil
      end

      private

      # FM-18: growth < slow_stall_bytes over slow_stall_window_s while
      # running → ALERT ONLY (the operator's authoritative stall signal,
      # deliberately replacing counter-based tripwires).
      def check_slow_stall!(at)
        window = Engine.config_value(@config, "engine.slow_stall_window_s")
        floor_bytes = Engine.config_value(@config, "engine.slow_stall_bytes")
        return if window.nil? || window <= 0

        earliest = @transcript_samples.take_while { |s| at - s[:at] >= window }.last
        return unless earliest

        grown = @transcript_samples.last[:bytes] - earliest[:bytes]
        return if grown >= floor_bytes

        return if @signalled_stall == earliest[:at]

        @signalled_stall = earliest[:at]
        signal(:slow_stall, "SLOWSTALL: transcript grew #{grown}B over #{window}s while running " \
                            "(floor #{floor_bytes}B) — ALERT ONLY: #{SLOWSTALL_ALERT_RULE}; " \
                            "if the unattended window elapses the quest pauses for the operator")
        nil
      end

      # The unattended window elapsing (no growth at all) → PAUSE, never kill.
      def check_unattended!(at)
        return if @paused_on_unattended

        unattended = Engine.config_value(@config, "engine.unattended_pause_s")
        return if unattended.nil? || unattended <= 0
        return unless (at - @last_growth_at) >= unattended

        @paused_on_unattended = true
        signal(:unattended_pause, "no transcript growth for #{unattended}s — the quest pauses " \
                                  "for the operator (FM-18: pause, never kill)")
        @pause_callback&.call
        nil
      end
    end
  end
end
