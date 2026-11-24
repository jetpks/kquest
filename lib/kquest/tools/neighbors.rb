# frozen_string_literal: true

module Kquest
  module Tools
    # Bounded-radius cycle-safe neighborhood of one node (I01 Q3's shape),
    # over derivation + evidence edges, capped at 50 aliases (T-CAP).
    class Neighbors < Base
      tool_name "neighbors"

      parameters do
        {"type" => "object",
         "properties" => {"node" => {"type" => "string"},
                          "types" => {"type" => "array",
                                      "items" => {"type" => "string",
                                                  "enum" => %w[derives_from supports contradicts]}},
                          "direction" => {"type" => "string", "enum" => %w[both in out]}}}
      end

      def execute(**args)
        node = find_claim(args[:node].to_s)
        refuse("neighbors", "unknown-node", id: args[:node].to_s) unless node

        cap = cfg("tools.cap_neighbors")
        rows = Kquest::Queries::Neighborhood.new(conn: conn)
                                            .hood(node.fetch(:id), user_id: user_id, quest_id: quest_id,
                                                  radius: 2, direction: args[:direction] || "both",
                                                  types: args[:types])
        aliases = rows.first(cap + 1).map do |r|
          preview =
            case r.fetch(:node_kind)
            when "claim"
              claim = conn[:claims].where(id: r.fetch(:node_id)).first
              "#{claim_alias(claim)} #{claim.fetch(:text)[0, 48]}"
            when "evidence"
              ev = conn[:evidence].where(id: r.fetch(:node_id)).first
              "E#{evidence_ordinal(ev)} #{ev.fetch(:span_text)[0, 48]}"
            when "source" then "source #{r.fetch(:node_id)}"
            else "frontier #{r.fetch(:node_id)}"
            end
          "depth #{r.fetch(:depth)} #{r.fetch(:node_kind)}: #{preview}"
        end
        lines = aliases.first(cap)
        lines << cap_note(n: cap, last_id: node_id_last(rows[cap - 1])) if aliases.size > cap
        lines.empty? ? "#{claim_alias(node)} has no neighbors within radius 2" : lines.join("\n")
      end

      private

      def node_id_last(row) = row.fetch(:node_kind) + "/" + row.fetch(:node_id).to_s[0, 8]
    end
  end
end
