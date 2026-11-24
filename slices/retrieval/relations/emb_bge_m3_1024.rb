# frozen_string_literal: true

module Retrieval
  module Relations
    class EmbBgeM31024 < Kquest::DB::Relation
      schema(:emb_bge_m3_1024, infer: true, as: :emb_bge_m3_1024) do
        attribute :embedding, ROM::SQL::Types::String
      end
    end
  end
end
