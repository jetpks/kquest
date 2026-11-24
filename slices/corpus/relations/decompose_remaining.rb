# frozen_string_literal: true

module Corpus
  module Relations
    class DecomposeRemaining < Kquest::DB::Relation
      schema(:v_decompose_remaining, infer: true, as: :decompose_remaining)
    end
  end
end
