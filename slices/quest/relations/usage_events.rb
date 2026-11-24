# frozen_string_literal: true

module Quest
  module Relations
    class UsageEvents < Kquest::DB::Relation
      schema(:usage_events, infer: true, as: :usage_events)
    end
  end
end
