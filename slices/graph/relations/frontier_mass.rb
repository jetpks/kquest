# frozen_string_literal: true

module Graph
  module Relations
    class FrontierMass < Kquest::DB::Relation
      schema(:v_frontier_mass, infer: true, as: :frontier_mass)
    end
  end
end
