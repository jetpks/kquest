# frozen_string_literal: true

module Kquest
  module Tools
    # Substring match over node TEXT (claims then evidence), capped (T-CAP —
    # the cap-continuation note teaches, never silent truncation); empty text
    # lists instead; id-probes are refused with the resolution recipe.
    class Search < Base
      tool_name "search"

      parameters do
        {"type" => "object",
         "properties" => {"text" => {"type" => "string"},
                          "label" => {"type" => "string", "enum" => %w[claim evidence]},
                          "after" => {"type" => "string"}}}
      end

      def execute(**args)
        text = args[:text].to_s
        if text.match?(/\A(K|E)\d+\z/) || text.start_with?("kb:")
          refuse("search", "id-probe")
        end
        return List.new(conn: conn, session: session, ledger: @ledger, config: config)
                   .execute(**args.slice(:label, :after)) if text.strip.empty?

        label = args[:label] || "claim"
        cap = cfg("tools.cap_search_rows")
        snippet = cfg("tools.cap_search_snippet_chars")

        rows = scope(label, text, args[:after])
        total = rows.count
        found = rows.limit(cap + 1).to_a
        _ = total

        lines = found.first(cap).map do |row|
          body = label == "claim" ? row.fetch(:text) : row.fetch(:reading)
          id = label == "claim" ? "K#{row.fetch(:quest_seq)}" : "E#{evidence_ordinal(row)}"
          "#{id} #{body[0, snippet]}#{body.length > snippet ? '…' : ''}"
        end
        if found.size > cap
          lines << cap_note(n: cap, last_id: last_id_for(label, found[cap - 1]))
        end
        lines.join("\n")
      end

      private

      # The principled order (L15): claims by quest_seq; evidence by the
      # (created_at, id) display order. `after:` resumes strictly past the
      # named row.
      def scope(label, text, after)
        if label == "claim"
          ds = conn[:claims].where(quest_id: quest_id, user_id: user_id)
                            .where(Sequel.lit("text LIKE ?", "%#{text}%"))
                            .order(:quest_seq)
          ds = ds.where(Sequel.lit("quest_seq > ?", after.delete_prefix("K").to_i)) if after
          ds
        else
          ds = conn[:evidence].where(quest_id: quest_id, user_id: user_id)
                              .where(Sequel.lit("reading LIKE ?", "%#{text}%"))
                              .order(:created_at, :id)
          ds = ds.where(Sequel.lit("(created_at, id) > (?, ?)", *after_cursor(after))) if after
          ds
        end
      end

      def after_cursor(after)
        row = evidence_by_ordinal(after.delete_prefix("E").to_i)
        raise ArgumentError, "unknown after cursor: #{after}" unless row

        [row.fetch(:created_at), row.fetch(:id)]
      end

      def last_id_for(label, row) = label == "claim" ? "K#{row.fetch(:quest_seq)}" : "E#{evidence_ordinal(row)}"
    end
  end
end
