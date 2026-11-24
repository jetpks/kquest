# frozen_string_literal: true

module Quest
  module Relations
    class QuestLineage < Kquest::DB::Relation
      schema(:v_quest_lineage, infer: true, as: :quest_lineage)
    end
  end
end
