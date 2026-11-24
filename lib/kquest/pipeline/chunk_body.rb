# frozen_string_literal: true

require "json"

module Kquest
  module Pipeline
    # The chunk body: the quest's staged sources (sources ⟕ quest_sources,
    # narrowed by the row's source_id when present), each snapshot read back
    # through the BlobUploader (location-addressed reconstitution — Grounds
    # decision 6: the IO path is the uploader's locations, NOT the GENERATED
    # blob-key columns), chunked per the strategy ROW's data, then written
    # from the cursor onward — per source ONE transaction (per-chunk REPLACE
    # on uq_chunks_source_strategy_ordinal + the cursor advance; a kill
    # between sources loses nothing, re-writes nothing). Completes with NO
    # usage row (chunking spends no tokens).
    class ChunkBody
      def initialize(conn: Kquest::App["db.gateway"].connection)
        @conn = conn
      end

      attr_reader :conn

      def run(row)
        strategy = conn[:chunk_strategies].where(id: row[:strategy_id]).first
        raise Error, "chunk strategy #{row[:strategy_id]} not found" unless strategy
        unless row[:quest_id]
          raise Error, "chunk job #{row[:id]} has no quest_id — the membership join needs the quest"
        end

        work = sources(row).map do |source|
          text = read_snapshot(source)
          list = Chunker.call(text,
            target_chars: strategy[:target_chars],
            overlap_chars: strategy[:overlap_chars],
            paragraph_aligned: strategy[:paragraph_aligned])
          [source, text, list]
        end
        total = work.sum { |_, _, list| list.size }

        if row[:done_items] > total
          raise Error, "chunk job #{row[:id]}: durable cursor #{row[:done_items]} is past the " \
                       "deterministic chunk list (#{total}) — the target set SHRANK; refusing to write"
        end

        State.mark_running!(conn, row, total)

        # Each source's chunk list occupies a cumulative range of the job's
        # deterministic list; the cursor always sits at a source boundary
        # (per-source transactions are atomic). A source whose range END is
        # past the cursor is REPLACED whole — its done_items advance to the
        # range end (an absolute cursor, never cursor + size: a partially
        # written source re-writes the source's already-durable head too).
        range_end = 0
        work.each do |source, text, list|
          range_end += list.size
          next if range_end <= row[:done_items] # fully written on an earlier pass

          replace_source_chunks!(row, source, strategy, text, list, range_end)
        end

        State.mark_complete!(conn, row, total)
        nil
      end

      private

      # Sequel hash-key joins do NOT qualify — explicit Sequel[:table][:col]
      # qualifications throughout (the digest's recorded seam).
      def sources(row)
        ds = conn[:sources]
          .join(:quest_sources,
                Sequel[:quest_sources][:source_id] => Sequel[:sources][:id],
                Sequel[:quest_sources][:user_id] => Sequel[:sources][:user_id])
          .where(Sequel[:quest_sources][:quest_id] => row[:quest_id],
                 Sequel[:sources][:user_id] => row[:user_id])
        ds = ds.where(Sequel[:sources][:id] => row[:source_id]) if row[:source_id]
        ds.order(Sequel[:sources][:id]).select_all(:sources)
      end

      # Grounds decision 6: read the snapshot back location-addressed via a
      # synthetic {"id": location, "storage": "store"} reconstitution (both
      # Shrine storages respond to open(id)).
      def read_snapshot(source)
        location = Kquest::BlobUploader.location_for(:snapshot, user: source[:user_id], source_urn: source[:urn])
        Kquest::BlobUploader.uploaded_file(JSON.generate({"id" => location, "storage" => "store"})).read
      end

      def replace_source_chunks!(row, source, strategy, snapshot_text, list, range_end)
        conn.transaction do
          # REPLACE semantics on uq_chunks_source_strategy_ordinal: delete
          # the source's chunks for this strategy, insert the list fresh.
          conn[:chunks].where(source_id: source[:id], strategy_id: strategy[:id]).delete
          list.each_with_index do |chunk, i|
            conn[:chunks].insert(
              source_id: source[:id],
              user_id: row[:user_id],
              strategy_id: strategy[:id],
              ordinal: i + 1,
              text: chunk.text,
              char_start: chunk.char_start,
              char_end: chunk.char_end,
              snapshot_char_count: snapshot_text.length,
              source_anchorable: source[:anchorable]
            )
          end
          conn[:embed_jobs].where(id: row[:id]).update(done_items: range_end)
        end
        nil
      end
    end
  end
end
