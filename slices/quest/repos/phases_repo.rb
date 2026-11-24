# frozen_string_literal: true

module Quest
  module Repos
    class PhasesRepo < Kquest::DB::Repo
      def by_pk(id)
        phases.by_pk(id).one
      end
    end
  end
end
