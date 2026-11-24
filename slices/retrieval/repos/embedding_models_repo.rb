# frozen_string_literal: true

module Retrieval
  module Repos
    class EmbeddingModelsRepo < Kquest::DB::Repo
      def by_pk(id)
        embedding_models.by_pk(id).one
      end
    end
  end
end
