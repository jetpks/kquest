# frozen_string_literal: true

module Corpus
  module Relations
    class QuestSources < Kquest::DB::Relation
      schema(:quest_sources, infer: true, as: :quest_sources)
    end
  end
end
