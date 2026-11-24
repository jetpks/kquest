# frozen_string_literal: true

module Graph
  module Relations
    class Evidence < Kquest::DB::Relation
      schema(:evidence, infer: true, as: :evidence)
    end
  end
end
