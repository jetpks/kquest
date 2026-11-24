# frozen_string_literal: true

module Kquest
  module Ui
    # The ONE shared visibility gate (I08 §4: "every read is visibility-
    # gated") — pages never hand-roll visibility. SELECT-only over
    # `v_resource_visibility` (I02): the owner sees their quest; anyone else
    # sees it only when one of its sources is PUBLIC-scope. This is the landed
    # quest-stream gate's own day-one semantics (F6, I15 judgment): the view's
    # aggregated scope cannot attribute workspace grants per-user; full
    # alignment lands with I17's grant-admin UI. Invisible quests 404 —
    # existence is never leaked.
    module Visibility
      module_function

      def visible_quest?(conn, user_id:, quest_id:)
        quest = conn[:quests].where(id: quest_id).first
        return false unless quest
        return true if quest.fetch(:user_id) == user_id

        conn[:quest_sources]
          .join(:v_resource_visibility,
                Sequel[:v_resource_visibility][:resource_id] => Sequel[:quest_sources][:source_id])
          .where(Sequel[:quest_sources][:quest_id] => quest_id,
                 Sequel[:v_resource_visibility][:resource_kind] => "source",
                 Sequel[:v_resource_visibility][:owner_user_id] => quest.fetch(:user_id),
                 Sequel[:v_resource_visibility][:effective_scope] => "public")
          .count.positive?
      end
    end
  end
end
