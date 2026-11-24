# frozen_string_literal: true

module Corpus
  module Repos
    class QuestSourcesRepo < Kquest::DB::Repo
      def by_pk(id)
        quest_sources.by_pk(id).one
      end
    end
  end
end
