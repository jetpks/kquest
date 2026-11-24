# frozen_string_literal: true

module Graph
  module Repos
    class ConflictsRepo < Kquest::DB::Repo
      def by_pk(id)
        conflicts.by_pk(id).one
      end
    end
  end
end
