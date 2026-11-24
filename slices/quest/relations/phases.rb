# frozen_string_literal: true

module Quest
  module Relations
    class Phases < Kquest::DB::Relation
      schema(:phases, infer: true, as: :phases)
    end
  end
end
