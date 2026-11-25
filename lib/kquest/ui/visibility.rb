# frozen_string_literal: true

module Kquest
  module Ui
    # The ONE shared visibility gate (I08 §4: "every read is visibility-
    # gated") — pages never hand-roll visibility. The per-viewer law is I02's
    # frozen M4: the owner sees their quest; anyone else sees it only when
    # one of its sources carries a grant row (owner-attributed) that is
    # public OR granted to the viewer OR granted to a workspace the viewer is
    # a member of (F6 closure, I20: the full alignment I16 recorded). The
    # aggregated `effective_scope` of `v_resource_visibility` cannot
    # attribute workspace grants per-user (the recorded I15 rationale); the
    # view remains the ladder surface (the dashboard's rendering, untouched).
    # Invisible quests 404 — existence is never leaked.
    module Visibility
      module_function

      def visible_quest?(conn, user_id:, quest_id:)
        quest = conn[:quests].where(id: quest_id).first
        return false unless quest
        return true if quest.fetch(:user_id) == user_id

        conn[:quest_sources]
          .join(:resource_grants,
                Sequel[:resource_grants][:source_id] => Sequel[:quest_sources][:source_id])
          .where(Sequel[:quest_sources][:quest_id] => quest_id,
                 Sequel[:resource_grants][:owner_user_id] => quest.fetch(:user_id))
          .where(
            Sequel[:resource_grants][:is_public] |
              Sequel.expr(Sequel[:resource_grants][:grantee_user_id] => user_id) |
              Sequel.lit("EXISTS (SELECT 1 FROM workspace_members wm " \
                         "WHERE wm.workspace_id = resource_grants.grantee_workspace_id " \
                         "AND wm.user_id = ?)", user_id)
          )
          .count.positive?
      end
    end
  end
end
