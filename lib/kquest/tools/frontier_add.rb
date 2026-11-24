# frozen_string_literal: true

module Kquest
  module Tools
    # Pose a claim on the scored work queue (I05 §2 / L4): need (NAMES the
    # underlying study — authors, year, venue), uncertainty and relevance
    # 1–5. The queue is computed-order (uncertainty × relevance desc) — never
    # re-add what is already open (uq_frontier_open_per_claim).
    class FrontierAdd < Base
      tool_name "frontier_add"

      parameters do
        {"type" => "object",
         "properties" => {
           "claim" => {"type" => "string"},
           "need" => {"type" => "string"},
           "uncertainty" => {"type" => "integer", "minimum" => 1, "maximum" => 5},
           "relevance" => {"type" => "integer", "minimum" => 1, "maximum" => 5}
         },
         "required" => %w[claim need uncertainty relevance]}
      end

      def mutates? = true

      def execute(**args)
        claim = find_claim(args[:claim].to_s)
        refuse("frontier_add", "unknown-node", id: args[:claim].to_s) unless claim

        u = args[:uncertainty]
        r = args[:relevance]
        unless u.is_a?(Integer) && r.is_a?(Integer) && u.between?(1, 5) && r.between?(1, 5)
          refuse("frontier_add", "score-range")
        end

        if conn[:frontier_entries].where(quest_id: quest_id, claim_id: claim[:id],
                                         state: "open").first
          refuse("frontier_add", "frontier-re-add", alias: claim_alias(claim))
        end

        need = args[:need].to_s
        if conn[:frontier_entries].where(quest_id: quest_id, need: need, state: "open").first
          existing = conn[:frontier_entries].where(quest_id: quest_id, need: need, state: "open").first
          existing_claim = conn[:claims].where(id: existing.fetch(:claim_id)).first
          refuse("frontier_add", "duplicate-need",
                 located: "\"#{need}\" on #{claim_alias(existing_claim)}")
        end

        id = conn[:frontier_entries].insert(
          user_id: user_id, quest_id: quest_id, claim_id: claim[:id], need: need,
          uncertainty: u, relevance: r, state: "open", spawned_by_phase_id: phase_id
        )
        entry = conn[:frontier_entries].where(id: id).first
        "frontier entry opened: #{claim_alias(claim)} uncertainty=#{entry[:uncertainty]} " \
          "relevance=#{entry[:relevance]} mass=#{entry[:uncertainty] * entry[:relevance]}"
      end
    end
  end
end
