# frozen_string_literal: true

module Graph
  module Repos
    class FrontierEntriesRepo < Kquest::DB::Repo
      def by_pk(id)
        frontier_entries.by_pk(id).one
      end
    end
  end
end
