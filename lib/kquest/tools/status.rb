# frozen_string_literal: true

module Kquest
  module Tools
    # The gate dashboard (I05 §5 — T-GATE): EXACTLY the parity fields, over
    # the SAME law views any phase gate sweeps. No decorative fields, no
    # invisible rules. The answer is the frozen shape with this quest's
    # values in the field slots (status=gate, 1:1 both directions).
    class Status < Base
      tool_name "status"

      parameters { {"type" => "object", "properties" => {}} }

      def execute(**_args)
        fields = Kquest::Queries::StatusSnapshot.new(conn: conn)
                                               .status_fields(user_id: user_id, quest_id: quest_id)
        "status: claims=#{fields[:claims]} evidence=#{fields[:evidence]} " \
          "decompose_remaining=#{fields[:decompose_remaining]} " \
          "frontier_open=#{fields[:frontier_open]} frontier_mass=#{fields[:frontier_mass]} " \
          "bare_claims=#{fields[:bare_claims]} unreferenced=#{fields[:unreferenced]} " \
          "dual_arm_claims=#{fields[:dual_arm_claims]}"
      end
    end
  end
end
