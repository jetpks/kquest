# frozen_string_literal: true

module Corpus
  module Repos
    class SourcesRepo < Kquest::DB::Repo
      def by_pk(id)
        sources.by_pk(id).one
      end
    end
  end
end
