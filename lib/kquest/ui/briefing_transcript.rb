# frozen_string_literal: true

require "json"

module Kquest
  module Ui
    # The briefing chat's transcript READER (I18 Spec Part 2.4 / AC13): the
    # session ledger blob parsed for the PAGE, through the ledger's OWN sink
    # seam — `TranscriptLedger.build_sink` (the env-switched builder,
    # stubbable — the I13 pattern) + `BlobUploader.location_for(:transcript,
    # session_id:)` — NEVER a second copy of transcript bytes (L8: the blob
    # is the audit log's single home; this module only READS it: no ledger
    # instance, no sessions write).
    #
    # Tail-capped (L15) via the seeded `ui.listing_cap.briefing_transcript`
    # row (config is the only cap source — CappedListing.cap_for; the row is
    # load-bearing: no DEFAULT_CAPS entry, so a wiped config raises loud),
    # with the HONEST omitted count (never silent truncation). Page lines:
    # `operator` (body), `final` (the assistant's text), `tool_call`/`
    # `tool_result` (tool + excerpt), `salvage` (marked — audit-only, never
    # rendered as an agent turn). The mapping law: PH0-CU-4.
    module BriefingTranscript
      # The L15 surface name — the seeded `ui.listing_cap.briefing_transcript`
      # row (I18 Part 1.9) is the ONLY cap source.
      CAP_SURFACE = "briefing_transcript"

      # The page-line excerpt clamp (rendering nicety, not a listing cap —
      # args/results/salvage payloads run long; the blob keeps the verbatim
      # bytes either way).
      EXCERPT_CHARS = 280

      module_function

      # The session's transcript as page props:
      # `{lines: [page-line, …], omitted: <n>}`. `cap:` overrides the seeded
      # row (tests); absent it, the row IS the cap.
      def for_session(conn, session, cap: nil)
        cap = CappedListing.cap_for(conn, CAP_SURFACE) if cap.nil?
        location = Kquest::BlobUploader.location_for(:transcript, session_id: session.fetch(:id))
        bytes = read_blob(Kquest::Engine::TranscriptLedger.build_sink, location)
        return {lines: [], omitted: 0} if bytes.nil? || bytes.strip.empty?

        mapped = parse(bytes).filter_map { |line| page_line(line) }
        kept = mapped.last(cap)
        {lines: kept, omitted: mapped.size - kept.size}
      end

      # ── the seam halves (each stubbable by its own name in tests) ──────

      # The sink READ. The FileSink raises Errno::ENOENT on a session with no
      # transcript yet (no lines ever appended); the MemorySink returns nil.
      # Both are the honest empty transcript.
      def read_blob(sink, location)
        sink.read(location)
      rescue Errno::ENOENT
        nil
      end

      # The blob's JSONL lines (the landed ledger write shape — one JSON
      # object per line; a torn trailing line never renders).
      def parse(bytes)
        bytes.split("\n").filter_map do |raw|
          JSON.parse(raw)
        rescue JSON::ParserError
          nil
        end
      end

      # ── the mapping (PH0-CU-4) ──────────────────────────────────────────

      def page_line(blob_line)
        case blob_line["type"]
        when "operator"
          {kind: "operator", body: blob_line["body"].to_s}
        when "final"
          text = assistant_text(blob_line["message"])
          text.empty? ? nil : {kind: "final", body: text}
        when "tool_call_start"
          call = blob_line["tool_call"] || {}
          {kind: "tool_call", tool: call["name"].to_s, excerpt: excerpt(call["arguments"])}
        when "tool_result"
          {kind: "tool_result", tool: blob_line["tool"].to_s,
           excerpt: excerpt(blob_line["content"]), is_error: blob_line["is_error"] == true}
        when "salvage"
          {kind: "salvage", body: excerpt(blob_line["message"]), marked: true}
        end
        # text_delta / thinking_delta (duplicates of the final) and
        # tool_call_end (duplicates of the start) render nothing.
      end

      # The `final` line's assistant text: the message content blocks of type
      # "text", joined. A tool-call-only final (the gem's tool-turn terminal)
      # yields "" — its calls render via the tool_call/tool_result lines.
      def assistant_text(message)
        content = message.is_a?(Hash) ? message["content"] : nil
        Array(content).filter_map do |block|
          block["text"] if block.is_a?(Hash) && block["type"] == "text"
        end.join("\n").strip
      end

      def excerpt(value)
        raw = value.is_a?(String) ? value : JSON.generate(value)
        raw = "" if raw.nil?
        raw.length > EXCERPT_CHARS ? "#{raw[0, EXCERPT_CHARS]}…" : raw
      end
    end
  end
end
