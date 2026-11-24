# frozen_string_literal: true

module Quest
  module Relations
    class Workspaces < Kquest::DB::Relation
      schema(:workspaces, infer: true, as: :workspaces)
    end
  end
end
