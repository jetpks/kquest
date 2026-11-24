# frozen_string_literal: true

module Quest
  module Relations
    class PhaseTransitions < Kquest::DB::Relation
      schema(:phase_transitions, infer: true, as: :phase_transitions)
    end
  end
end
