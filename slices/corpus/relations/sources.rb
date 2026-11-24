# frozen_string_literal: true

module Corpus
  module Relations
    class Sources < Kquest::DB::Relation
      schema(:sources, infer: true, as: :sources)
    end
  end
end
