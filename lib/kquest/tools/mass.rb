# frozen_string_literal: true

module Kquest
  module Tools
    # Frontier mass Σ(uncertainty × relevance) over open entries + open count
    # (I01 `v_frontier_mass`; the L4 quantity the transition law reads).
    class Mass < Base
      tool_name "mass"

      parameters { {"type" => "object", "properties" => {}} }

      def execute(**_args)
        row = conn[:v_frontier_mass].where(quest_id: quest_id).first
        mass = row ? row.fetch(:mass) : 0
        open = row ? row.fetch(:open_entries) : 0
        "mass: frontier_mass=#{mass} frontier_open=#{open}"
      end
    end
  end
end
