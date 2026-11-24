# frozen_string_literal: true

module Graph
  module Relations
    class EvidenceEdges < Kquest::DB::Relation
      schema(:evidence_edges, infer: true, as: :evidence_edges)
    end
  end
end
