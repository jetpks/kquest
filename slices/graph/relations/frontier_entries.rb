# frozen_string_literal: true

module Graph
  module Relations
    class FrontierEntries < Kquest::DB::Relation
      schema(:frontier_entries, infer: true, as: :frontier_entries)
    end
  end
end
