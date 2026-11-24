# frozen_string_literal: true

module Corpus
  module Repos
    class ChunksRepo < Kquest::DB::Repo
      def by_pk(id)
        chunks.by_pk(id).one
      end
    end
  end
end
