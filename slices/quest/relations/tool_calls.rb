# frozen_string_literal: true

module Quest
  module Relations
    class ToolCalls < Kquest::DB::Relation
      schema(:tool_calls, infer: true, as: :tool_calls)
    end
  end
end
