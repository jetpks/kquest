# frozen_string_literal: true

module Graph
  module Relations
    class FrontierOpen < Kquest::DB::Relation
      schema(:v_frontier_open, infer: true, as: :frontier_open)
    end
  end
end
