# frozen_string_literal: true

module Quest
  module Relations
    class LadderPasses < Kquest::DB::Relation
      schema(:ladder_passes, infer: true, as: :ladder_passes)
    end
  end
end
