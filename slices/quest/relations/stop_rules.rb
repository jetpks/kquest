# frozen_string_literal: true

module Quest
  module Relations
    class StopRules < Kquest::DB::Relation
      schema(:stop_rules, infer: true, as: :stop_rules)
    end
  end
end
