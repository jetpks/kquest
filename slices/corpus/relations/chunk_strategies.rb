# frozen_string_literal: true

module Corpus
  module Relations
    class ChunkStrategies < Kquest::DB::Relation
      schema(:chunk_strategies, infer: true, as: :chunk_strategies)
    end
  end
end
