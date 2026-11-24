# frozen_string_literal: true

module Watch
  module Actions
    # GET /quests/:quest_id/stream — the quest-watch stream (I08 §3). Gates in
    # #handle FIRST (the standard session posture + the quest's
    # `v_resource_visibility` check — I02) BEFORE `render_stream`: halting
    # first keeps the error response ordinary JSON; once the SSE headers are
    # set, an error can only surface as a broken stream. The URL shape is the
    # frozen contract for ENTRY 5.
    class QuestStream < Kquest::StreamAction
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        unless user
          res.status = 403
          res.content_type = JSON_CONTENT_TYPE
          res.body = JSON.generate(error: "Forbidden")
          return
        end

        quest = conn[:quests].where(id: req.params[:quest_id]).first
        return halt_not_found(res) unless quest
        return halt_not_found(res) unless visible?(user, quest)

        render_stream(req, res, key: "kquest:sse:quest:#{quest.fetch(:id)}")
      end

      private

      def conn = gateway.connection

      # The quest's visibility (I02): the owner sees their quest; anyone else
      # sees it only when one of its sources is PUBLIC-scope in
      # `v_resource_visibility` (per-user sources shared through workspaces +
      # grants — the workspace/member check is the grant rows' own law; the
      # shared scope requires a grant THIS user's workspaces hold, which the
      # view's aggregated scope cannot attribute, so day one the non-owner
      # gate is ownership or public). Invisible quests 404 — existence is
      # never leaked.
      def visible?(user, quest)
        return true if quest.fetch(:user_id) == user.id

        conn[:quest_sources]
          .join(:v_resource_visibility,
                Sequel[:v_resource_visibility][:resource_id] => Sequel[:quest_sources][:source_id])
          .where(Sequel[:quest_sources][:quest_id] => quest.fetch(:id),
                 Sequel[:v_resource_visibility][:resource_kind] => "source",
                 Sequel[:v_resource_visibility][:owner_user_id] => quest.fetch(:user_id),
                 Sequel[:v_resource_visibility][:effective_scope] => "public")
          .count.positive?
      end
    end
  end
end
