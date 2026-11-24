# frozen_string_literal: true

module Quest
  module Repos
    class LadderPassesRepo < Kquest::DB::Repo
      def by_pk(id)
        ladder_passes.by_pk(id).one
      end
    end
  end
end
