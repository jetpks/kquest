# frozen_string_literal: true

module Kquest
  module Tools
    # The capped node listing (I05 §2 / L15): claims then evidence, id
    # ascending — principled order, never shuffled; the cold-boot overview;
    # cap continuation teaches, never silently truncates. The frozen answer
    # shape: `K<n> [urn] claim <text-snippet> …`.
    class List < Base
      tool_name "list"

      parameters do
        {"type" => "object",
         "properties" => {"label" => {"type" => "string"},
                          "after" => {"type" => "string"}}}
      end

      def execute(**args)
        label = args[:label] || "claim"
        refuse("list", "unknown-label", named: "UNKNOWN-LABEL: #{label}") unless %w[claim evidence].include?(label)

        cap = cfg("tools.cap_list_rows")
        snippet = 80
        rows = scope(label, args[:after]).limit(cap + 1).to_a

        lines = rows.first(cap).map do |row|
          if label == "claim"
            body = row.fetch(:text)
            "K#{row.fetch(:quest_seq)} [#{row.fetch(:urn)}] claim " \
              "#{body[0, snippet]}#{body.length > snippet ? '…' : ''}"
          else
            body = row.fetch(:reading)
            "E#{evidence_ordinal(row)} [#{row.fetch(:span_start)}..#{row.fetch(:span_end)}] evidence " \
              "#{body[0, snippet]}#{body.length > snippet ? '…' : ''}"
          end
        end
        if rows.size > cap
          last = rows[cap - 1]
          lines << cap_note(n: cap, last_id: label == "claim" ? "K#{last.fetch(:quest_seq)}" : "E#{evidence_ordinal(last)}")
        end
        lines.join("\n")
      end

      private

      def scope(label, after)
        if label == "claim"
          ds = conn[:claims].where(quest_id: quest_id, user_id: user_id).order(:quest_seq)
          ds = ds.where(Sequel.lit("quest_seq > ?", after.delete_prefix("K").to_i)) if after
          ds
        else
          ds = conn[:evidence].where(quest_id: quest_id, user_id: user_id).order(:created_at, :id)
          ds = ds.where(Sequel.lit("(created_at, id) > (?, ?)", *after_cursor(after))) if after
          ds
        end
      end

      def after_cursor(after)
        row = evidence_by_ordinal(after.delete_prefix("E").to_i)
        raise ArgumentError, "unknown after cursor: #{after}" unless row

        [row.fetch(:created_at), row.fetch(:id)]
      end
    end
  end
end
