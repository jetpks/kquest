# frozen_string_literal: true

module Graph
  module Relations
    class Conflicts < Kquest::DB::Relation
      schema(:conflicts, infer: true, as: :conflicts)
    end
  end
end
