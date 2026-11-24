# frozen_string_literal: true

module Graph
  module Relations
    class CanonicalClaims < Kquest::DB::Relation
      schema(:v_canonical_claims, infer: true, as: :canonical_claims)
    end
  end
end
