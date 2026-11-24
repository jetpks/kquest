# frozen_string_literal: true

module Quest
  module Relations
    class Quests < Kquest::DB::Relation
      schema(:quests, infer: true, as: :quests)
    end
  end
end
