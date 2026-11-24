# frozen_string_literal: true

module Quest
  module Relations
    class WorkspaceMembers < Kquest::DB::Relation
      schema(:workspace_members, infer: true, as: :workspace_members)
    end
  end
end
