# frozen_string_literal: true

module Graph
  module Relations
    class Claims < Kquest::DB::Relation
      schema(:claims, infer: true, as: :claims)
    end
  end
end
