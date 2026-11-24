# frozen_string_literal: true

require "json"
require "pathname"

module Kquest
  module Engine
    # The L8 verbatim transcript (I04 §2.1, R-013): appends the session's
    # transcript to the CHECK-law blob location
    # `sessions/<session-uuid>/transcript.jsonl` — the layout's SINGLE home is
    # `Kquest::BlobUploader.location_for(:transcript, session_id:)` — and
    # stores that location in `sessions.transcript_blob_key` (CHECK-satisfying).
    # Writes `tool_calls` rows in the same transaction as the mutation (the
    # ToolHarness's transaction; I01 §3.15). Persists SALVAGED partials as
    # audit — never auto-appended to the live history (FM-13/FM-15).
    #
    # The append IO seam mirrors the uploader's env switch (the digest seam:
    # Shrine storages are IN-MEMORY in test): in-memory in test env (hermetic
    # suite), append-mode files at the uploader's dev/prod store root
    # otherwise.
    class TranscriptLedger
      # Append-mode sink. In test: a Hash of location → String. Otherwise:
      # files under the store root the uploader itself uses in dev/prod.
      class MemorySink
        attr_reader :blobs

        def initialize = @blobs = {}

        def append(location, bytes) = (@blobs[location] = (@blobs[location] || +"") + bytes)
        def read(location) = @blobs[location]
        def size(location) = (@blobs[location] || "").bytesize
      end

      class FileSink
        def initialize(root) = @root = Pathname(root)

        def append(location, bytes)
          path = @root.join(location)
          path.parent.mkpath
          path.open("a") { |f| f.write(bytes) }
          nil
        end

        def read(location) = @root.join(location).read
        def size(location) = @root.join(location).size
      end

      def self.build_sink
        if Hanami.env?(:test)
          MemorySink.new
        else
          storage = Kquest::BlobUploader.storages.fetch(:store)
          root = storage.respond_to?(:folder) ? storage.folder : storage.root
          FileSink.new(root)
        end
      end

      # conn: the Sequel connection; session: the tenancy hash
      # ({id:, user_id:, quest_id:, phase_id:, model:}); sink: an append
      # sink (built per env by default; injectable for tests).
      def initialize(conn:, session:, sink: TranscriptLedger.build_sink)
        @conn = conn
        @session = session
        @sink = sink
        @location = Kquest::BlobUploader.location_for(:transcript, session_id: session.fetch(:id))
        @buffer = +""
        @buffered_salvage = false
        register_key!
      end

      attr_reader :location, :sink

      # The transcript's live byte size (StreamWatch's growth input).
      def bytes = @sink.size(@location)

      # ── stream-event observation (the loop yields every event here) ────
      # Events buffer; the turn transaction flushes them — the transcript
      # append lands atomically with the turn's spend rows.

      def observe(event)
        case event.type
        when :text_delta then buffer({type: "text_delta", text: event.delta})
        when :thinking_delta then buffer({type: "thinking_delta", thinking: event.delta})
        when :tool_call_start then buffer({type: "tool_call_start", tool_call: event.tool_call})
        when :tool_call_end then buffer({type: "tool_call_end", tool_call: event.tool_call})
        when :error
          # A salvage terminal (FM-13/FM-15): the partial is AUDIT — marked as
          # such on its own line type, never merged into live history. (The
          # terminal events carry the partial in `message`, not `partial`.)
          partial = event.message || event.partial
          @buffered_salvage = true
          buffer({type: "salvage", message: partial&.to_h})
        end
        nil
      end

      # The turn transaction's ledger write: everything observed this turn
      # (verbatim) plus the final message.
      def append_turn(final:, turn:, stop_reason: nil)
        buffer({type: "final", turn: turn, stop_reason: stop_reason, message: final&.to_h})
        flush_buffer!
        nil
      end

      # Persist the salvage buffer on a failure path (the loop's rescue arm):
      # the salvaged partial + its usage were observed via `:error` — they
      # land as audit even though the turn raised.
      def flush_salvage!
        flush_buffer! if @buffered_salvage
        nil
      end

      # A cancelled turn appends NOTHING (FM-19: the half-streamed turn is
      # never appended; no phantom terminal).
      def drop_buffer!
        @buffer.clear
        @buffered_salvage = false
        nil
      end

      # The tool RESULT line (the verbatim transcript's tool results — the
      # refusal texts included). The ToolHarness calls this next to its audit
      # row, inside the same transaction.
      def record_tool_result!(tool:, args:, content:, is_error:)
        buffer({type: "tool_result", tool: tool, args: args, content: content, is_error: is_error})
        nil
      end

      # The `tool_calls` audit row (E-AUDIT): written by the ToolHarness
      # INSIDE its same-transaction Sequel transaction. seq is per session
      # (uq_tool_calls_session_seq); ok/error shape law per I01
      # (ok ⇒ error_class nil; !ok ⇒ error_class present).
      def record_tool_call!(tool:, op: nil, args:, result:, ok:, error_class: nil)
        seq = @conn[:tool_calls].where(session_id: @session.fetch(:id)).max(:seq).to_i + 1
        # jsonb columns take explicit-cast literals (raw Sequel inserts bind
        # Hashes only through the pg_json extension — the cast keeps this
        # dependency-free).
        @conn[:tool_calls].insert(
          user_id: @session.fetch(:user_id), quest_id: @session.fetch(:quest_id),
          session_id: @session.fetch(:id), seq: seq,
          tool: tool, op: op,
          args: Sequel.lit("?::jsonb", JSON.generate(args)),
          result: Sequel.lit("?::jsonb", JSON.generate(result)),
          ok: ok, error_class: error_class
        )
        nil
      end

      private

      def buffer(line)
        @buffer << JSON.generate(line) << "\n"
        nil
      end

      def flush_buffer!
        @sink.append(@location, @buffer) unless @buffer.empty?
        @buffer = +""
        @buffered_salvage = false
        nil
      end

      # Store the CHECK-satisfying location on the session row (idempotent;
      # the CHECK `^sessions/<uuid>/transcript\.jsonl$` is I01 law — this
      # value conforms to the schema, never the reverse).
      def register_key!
        @conn[:sessions].where(id: @session.fetch(:id))
                        .update(transcript_blob_key: @location)
        nil
      end
    end
  end
end
