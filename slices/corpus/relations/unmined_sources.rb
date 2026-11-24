# frozen_string_literal: true

module Corpus
  module Relations
    class UnminedSources < Kquest::DB::Relation
      schema(:v_unmined_sources, infer: true, as: :unmined_sources)
    end
  end
end
