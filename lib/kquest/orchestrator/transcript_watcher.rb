# frozen_string_literal: true

require_relative "../engine/stream_watch"

module Kquest
  module Orchestrator
    # The transcript watcher (I07 DR-07's byte-accurate LIVE half; I08 §2.4):
    # it tails the session transcript blob's byte growth — read through the
    # landed TranscriptLedger IO-sink seam (`size(location)` — the SAME bytes
    # the ledger appends, L8; NEVER a second copy of transcript bytes; the
    # ledger objects themselves are supplied by the hosting quest worker via
    # the `ledger_for:` seam) — on a periodic census while the quest's
    # sessions run.
    #
    # It evaluates the SAME I06 stop-rule keys the SQL projections read —
    # `engine.slow_stall_bytes` (100) over `engine.slow_stall_window_s`
    # (1200), `engine.transcript_ceiling_warn_bytes` (450000),
    # `engine.transcript_ceiling_hard_bytes` (496000),
    # `engine.unattended_pause_s` (3600) — hosting/feeding the landed
    # StreamWatch signal logic for the slow-stall rule (it fits) and
    # computing the unattended window from its OWN census timestamps (the
    # landed StreamWatch never advances its last-growth marker — see the
    # builder report's PHASE 0 note 3; no engine edit).
    #
    # FM-18 / eval-not-binding: the watcher NEVER kills anything, never ends
    # a session, never transitions a phase — it DETECTS and SIGNALS: the
    # `watcher.bytes` census event, the `assurance_alert` signals under the
    # same config keys, and the `transcript_bytes`/`transcript_growth` guard
    # values the runner's `transcript_ceiling`/`slow_stall_unattended` rows
    # consume at the boundary. FM-14's dropped-chunk count rides the same
    # census (the gem's counter via StreamWatch).
    class TranscriptWatcher
      WATCH_EVENT = "watcher.bytes"
      ALERT_EVENT = "assurance_alert"

      def initialize(quest_id:, publisher:, config:, interval_s: 1, ledger_for: nil)
        @quest_id = quest_id
        # The ledger seam: the hosting quest worker REGISTERS the session
        # ledgers it drives (the runner's per-attempt TranscriptLedger
        # objects); `ledger_for:` overrides for tests/harnesses that supply
        # their own map. Either way the census reads the ledger's OWN sink —
        # the SAME bytes the ledger appends (L8), never a second copy.
        @ledger_for = ledger_for
        @ledgers = {}
        @publisher = publisher
        @config = config
        @interval_s = interval_s
        @samples = Hash.new { |h, k| h[k] = [] } # session_id → [{at:, bytes:}]
        @last_growth_at = {}                     # session_id → time of last byte growth
        @watches = {}                            # session_id → the hosted StreamWatch
        @seen_signals = Hash.new(0)              # session_id → signals already reported
        @ceiling_signalled = {}                  # session_id → band already signalled
      end

      # The hosting runner registers/unregisters its live session ledgers.
      def register_ledger(session_id, ledger)
        @ledgers[session_id] = ledger
        nil
      end

      def release_ledger(session_id)
        @ledgers = @ledgers.reject { |k, _v| k == session_id }
        @samples[session_id] = [] if @ledgers.empty?
        nil
      end

      # One census pass over the quest's live ledgers. Returns the per-session
      # records: [{session_id:, transcript_bytes:, growth_bytes:, window_s:, signals:}].
      def census(at: Time.now)
        window_s = config_value("engine.slow_stall_window_s") || 1200
        out = []
        ledgers = @ledger_for ? @ledger_for.call : @ledgers
        ledgers.each do |session_id, ledger|
          bytes = ledger.bytes # the sink seam: the SAME bytes the ledger appends
          record = observe(session_id, bytes, window_s, at)
          out << record
          publish_census(record)
        end
        out
      end

      # The runner's guard inputs (the same numbers the census published).
      def bytes_for(session_id)
        @samples[session_id].last&.fetch(:bytes)
      end

      def growth_for(session_id, window_s)
        samples = @samples[session_id]
        return nil if samples.empty?

        cutoff = samples.last.fetch(:at) - window_s
        earliest = samples.take_while { |s| s.fetch(:at) <= cutoff }.last ||
                   samples.first
        samples.last.fetch(:bytes) - earliest.fetch(:bytes)
      end

      private

      def observe(session_id, bytes, window_s, at)
        samples = @samples[session_id]
        previous = samples.last&.fetch(:bytes)
        samples << {at: at, bytes: bytes}
        @last_growth_at[session_id] ||= at
        @last_growth_at[session_id] = at if previous.nil? || bytes != previous

        growth = growth_for(session_id, window_s)
        signals = check_signals(session_id, bytes, growth, window_s, at)
        {session_id: session_id, transcript_bytes: bytes, growth_bytes: growth,
         window_s: window_s, signals: signals}
      end

      # The signal evaluation — DETECT and SIGNAL, nothing more (the
      # consequence is the I06 transition row's, fired by the RUNNER at the
      # boundary; FM-18: never auto-kill).
      def check_signals(session_id, bytes, growth, window_s, at)
        signals = []
        signals.concat(drain_stream_watch(session_id, bytes, at))
        signals.concat(ceiling_signals(session_id, bytes))
        if growth && growth < (config_value("engine.slow_stall_bytes") || 100) &&
           window_elapsed?(session_id, window_s, at)
          signals << {type: "slow_stall", key: "engine.slow_stall_bytes",
                      detail: "byte-accurate: transcript grew #{growth}B over #{window_s}s " \
                              "(floor #{config_value('engine.slow_stall_bytes')}B) — ALERT ONLY: " \
                              "the driver is NOT to be killed on this signal alone"}
        end
        unattended = config_value("engine.unattended_pause_s") || 3600
        if @last_growth_at[session_id] && (at - @last_growth_at[session_id]) >= unattended
          signals << {type: "unattended", key: "engine.unattended_pause_s",
                      detail: "no transcript growth for #{unattended}s — the I06 " \
                              "slow_stall_unattended row owns the pause (FM-18: never kill)"}
        end
        signals.each do |s|
          @publisher&.publish_quest(@quest_id, ALERT_EVENT,
                                    {"quest_id" => @quest_id.to_s,
                                     "session_id" => session_id.to_s,
                                     "predicate" => s[:key], "signal" => s[:type],
                                     "detail" => s[:detail]})
        end
        signals
      end

      # The landed StreamWatch hosts the slow-stall rule: the watcher FEEDS it
      # the byte census and drains its signals (the alert text is its law).
      def drain_stream_watch(session_id, bytes, at)
        watch = (@watches[session_id] ||= Kquest::Engine::StreamWatch.new(
          conn: nil, session: {id: session_id}, config: @config
        ))
        watch.observe_transcript!(bytes, at: at)
        fresh = watch.signals[@seen_signals[session_id]..] || []
        @seen_signals[session_id] = watch.signals.size
        fresh.map do |s|
          {type: s[:type].to_s, key: "engine.slow_stall_bytes", detail: s[:message]}
        end
      end

      def ceiling_signals(session_id, bytes)
        warn_bytes = config_value("engine.transcript_ceiling_warn_bytes") || 450_000
        hard_bytes = config_value("engine.transcript_ceiling_hard_bytes") || 496_000
        band = bytes >= hard_bytes ? "hard" : (bytes >= warn_bytes ? "warn" : nil)
        return [] unless band
        return [] if @ceiling_signalled[session_id] == band

        @ceiling_signalled[session_id] = band
        [{type: "size_ceiling", key: "engine.transcript_ceiling_#{band}_bytes",
          detail: "byte-accurate live transcript at #{bytes}B entered the #{band} ceiling " \
                  "band (#{band == 'hard' ? hard_bytes : warn_bytes}B) — the I06 " \
                  "transcript_ceiling row owns the consequence at the boundary"}]
      end

      def window_elapsed?(session_id, window_s, at)
        samples = @samples[session_id]
        return false if samples.size < 2

        (at - samples.first.fetch(:at)) >= window_s
      end

      def publish_census(record)
        @publisher&.publish_quest(@quest_id, WATCH_EVENT,
                                  {"quest_id" => @quest_id.to_s,
                                   "session_id" => record[:session_id].to_s,
                                   "transcript_bytes" => record[:transcript_bytes],
                                   "growth_bytes" => record[:growth_bytes],
                                   "window_s" => record[:window_s],
                                   "dropped_chunks" => dropped_chunks(record[:session_id])})
        nil
      end

      # FM-14's dropped-chunk count rides the census (the gem's counter via
      # the hosted StreamWatch — a runtime counter, never a tool_calls class).
      def dropped_chunks(session_id)
        @watches[session_id]&.dropped_chunks || 0
      end

      def config_value(key)
        line = @config[key]
        line && (line.is_a?(Hash) ? line.fetch(:value) : line)
      end
    end
  end
end
