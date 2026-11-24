# frozen_string_literal: true

module Kquest
  module Relations
    class Documents < Kquest::DB::Relation
      schema(:documents, infer: true)
    end
  end
end
