# frozen_string_literal: true

module Graph
  module Relations
    class ClaimDerivations < Kquest::DB::Relation
      schema(:claim_derivations, infer: true, as: :claim_derivations)
    end
  end
end
