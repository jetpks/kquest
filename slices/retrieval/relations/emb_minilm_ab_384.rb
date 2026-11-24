# frozen_string_literal: true

module Retrieval
  module Relations
    class EmbMinilmAb384 < Kquest::DB::Relation
      schema(:emb_minilm_ab_384, infer: true, as: :emb_minilm_ab_384) do
        attribute :embedding, ROM::SQL::Types::String
      end
    end
  end
end
