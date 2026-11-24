# frozen_string_literal: true

module Retrieval
  module Relations
    class EmbeddingModels < Kquest::DB::Relation
      schema(:embedding_models, infer: true, as: :embedding_models)
    end
  end
end
