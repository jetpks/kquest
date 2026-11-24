# frozen_string_literal: true

module Quest
  module Repos
    class PhaseTransitionsRepo < Kquest::DB::Repo
      def by_pk(id)
        phase_transitions.by_pk(id).one
      end
    end
  end
end
