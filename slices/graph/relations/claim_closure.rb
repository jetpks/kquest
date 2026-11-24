# frozen_string_literal: true

module Graph
  module Relations
    class ClaimClosure < Kquest::DB::Relation
      schema(:v_claim_closure, infer: true, as: :claim_closure)
    end
  end
end
