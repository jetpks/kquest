# frozen_string_literal: true

module Graph
  module Relations
    class ConflictSources < Kquest::DB::Relation
      schema(:conflict_sources, infer: true, as: :conflict_sources)
    end
  end
end
