# frozen_string_literal: true

module Kquest
  module Tools
    # Ordered typed edge: `derives_from` claim→claim (position = max+1); a
    # wired claim carries no terminal — clear via node_set first. Evidence
    # links to claims through node_add label=evidence, never edge_add.
    class EdgeAdd < Base
      tool_name "edge_add"

      parameters do
        {"type" => "object",
         "properties" => {
           "from" => {"type" => "string"},
           "type" => {"type" => "string", "enum" => ["derives_from"]},
           "to" => {"type" => "string"}
         },
         "required" => %w[from to]}
      end

      def mutates? = true

      def execute(**args)
        from = find_claim(args[:from].to_s)
        refuse("edge_add", "unknown-node", id: args[:from].to_s) unless from

        # An evidence (E-id) or source target is the wrong-endpoint class: the
        # evidence-links-via-node_add recipe, not unknown-node.
        if args[:to].to_s.match?(/\AE\d+\z/) || args[:to].to_s.start_with?("kb:src:")
          refuse("edge_add", "wrong-endpoint", got: "got evidence")
        end

        to = find_claim(args[:to].to_s)
        refuse("edge_add", "unknown-node", id: args[:to].to_s) unless to

        refuse("edge_add", "self-derivation",
               alias: claim_alias(from)) if from[:id] == to[:id]

        if conn[:claim_derivations].where(claim_id: from[:id], parent_claim_id: to[:id],
                                          quest_id: quest_id).first
          refuse("edge_add", "duplicate-edge",
                 from: claim_alias(from), to: claim_alias(to))
        end

        position = (conn[:claim_derivations].where(claim_id: from[:id]).max(:position) || 0) + 1
        conn[:claim_derivations].insert(
          user_id: user_id, quest_id: quest_id, claim_id: from[:id],
          parent_claim_id: to[:id], position: position
        )
        "#{claim_alias(from)} derives_from #{claim_alias(to)} (position #{position})"
      end
    end
  end
end
