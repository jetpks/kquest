# frozen_string_literal: true

module Quest
  module Relations
    class QuestLifecycleEvents < Kquest::DB::Relation
      schema(:quest_lifecycle_events, infer: true, as: :quest_lifecycle_events)
    end
  end
end
