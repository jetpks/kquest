# frozen_string_literal: true

module Corpus
  module Relations
    class Chunks < Kquest::DB::Relation
      schema(:chunks, infer: true, as: :chunks) do
        attribute :search_tsv, ROM::SQL::Types::String.optional
      end
    end
  end
end
