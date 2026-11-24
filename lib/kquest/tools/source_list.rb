# frozen_string_literal: true

module Kquest
  module Tools
    # The staged-corpus listing (I05 §2): C-id, title, role (citable/agenda),
    # snapshot chars, chunk/embed state — staging order, capped with a
    # teaching continuation (L15). The C-id IS the staging ordinal (the same
    # (added_at, source_id) index the binding pass reserves — one law).
    class SourceList < Base
      tool_name "source_list"

      parameters { {"type" => "object", "properties" => {"after" => {"type" => "string"}}} }

      def execute(**args)
        cap = cfg("tools.cap_source_list_rows")
        index = Kquest::Queries.source_index(conn, user_id: user_id, quest_id: quest_id)
        start = args[:after] ? args[:after].delete_prefix("C").to_i : 0
        rows = index[start, cap + 1] || []

        chunk_state = chunk_state(rows)
        lines = rows.first(cap).map.with_index(start) do |row, i|
          chunks = chunk_state[row.fetch(:id)]
          "C#{i + 1} [#{row.fetch(:urn)}] #{row.fetch(:role)} \"#{row.fetch(:title)}\" " \
            "#{row.fetch(:snapshot_char_count)} chars chunks=#{chunks[:chunks]} " \
            "#{chunks[:embedded] ? 'embedded' : 'not-embedded'}"
        end
        if rows.size > cap
          lines << cap_note(n: cap, last_id: "C#{start + cap}")
        end
        lines.empty? ? "no sources staged" : lines.join("\n")
      end

      private

      # The chunk/embed state per source: the chunk rows for the day-one
      # strategy + whether vectors exist for them (the embed leg's state).
      def chunk_state(rows)
        return {} if rows.empty?

        ids = rows.map { |r| r.fetch(:id) }
        counts = Hash.new(0)
        conn[:chunks].where(source_id: ids).each { |c| counts[c.fetch(:source_id)] += 1 }
        embedded = Hash.new(false)
        unless counts.empty?
          strategy_ids = conn[:chunks].where(source_id: ids).select(:strategy_id).distinct.map { |r| r[:strategy_id] }
          chunk_ids = conn[:chunks].where(source_id: ids).select(:id).map { |r| r[:id] }
          unless chunk_ids.empty?
            tables = conn[:embedding_models].where(status: "active").select(:table_name).map { |r| r[:table_name] }
            tables.each do |table|
              next unless table =~ /\Aemb_[a-z0-9_]+\z/

              embedded[true] = true if conn[table.to_sym].where(chunk_id: chunk_ids).count.positive?
            end
            _ = strategy_ids
          end
        end
        rows.to_h do |r|
          n = counts[r.fetch(:id)]
          [r.fetch(:id), {chunks: n, embedded: n.positive? && embedded[true]}]
        end
      end
    end
  end
end
