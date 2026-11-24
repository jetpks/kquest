# frozen_string_literal: true

module Kquest
  module Tools
    # Close an OPEN frontier entry; closed entries stay history forever
    # (never deleted); refuses closes that would leave the claim satisfying
    # nothing (the three legal moves are in the frozen text).
    class FrontierClose < Base
      tool_name "frontier_close"

      parameters do
        {"type" => "object",
         "properties" => {"claim" => {"type" => "string"},
                          "closure_type" => {"type" => "string",
                                             "enum" => %w[fetch internal refusal]}},
         "required" => ["claim"]}
      end

      def mutates? = true

      def execute(**args)
        claim = find_claim(args[:claim].to_s)
        refuse("frontier_close", "unknown-node", id: args[:claim].to_s) unless claim

        open = conn[:frontier_entries].where(quest_id: quest_id, claim_id: claim[:id],
                                             state: "open").first
        refuse("frontier_close", "no-open-entry", alias: claim_alias(claim)) unless open

        # The closure contract (L6): closing the LAST open entry must leave
        # the claim satisfying something — terminal ∨ derives_from ∨ another
        # open entry.
        still = conn[:v_claim_closure].where(claim_id: claim[:id]).first
        more_open = conn[:frontier_entries]
                    .where(quest_id: quest_id, claim_id: claim[:id], state: "open")
                    .exclude(id: open[:id]).count.positive?
        if still[:terminal_type].nil? &&
           conn[:claim_derivations].where(claim_id: claim[:id]).count.zero? && !more_open
          refuse("frontier_close", "closure-violation", alias: claim_alias(claim))
        end

        conn[:frontier_entries].where(id: open[:id]).update(
          state: "closed", closed_at: Time.now, closure_type: args[:closure_type] || "internal"
        )
        "#{claim_alias(claim)} frontier entry closed (#{args[:closure_type] || 'internal'})"
      end
    end
  end
end
