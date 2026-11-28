# frozen_string_literal: true

module Watch
  module Actions
    # GET /quests/:quest_id/stream — the quest-watch stream (I08 §3). Gates in
    # #handle FIRST (the standard session posture + the ONE shared visibility
    # gate — the I02 M4 per-viewer check; F6 closure, I20: the stream's own
    # owner-or-public copy is GONE, the shared helper is the gate exactly as
    # for the 13 read actions) BEFORE `render_stream`: halting
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
        return halt_not_found(res) unless Kquest::Ui::Visibility.visible_quest?(conn, user_id: user.id,
                                                                                              quest_id: quest.fetch(:id))

        render_stream(req, res, key: "kquest:sse:quest:#{quest.fetch(:id)}")
      end

      private

      def conn = gateway.connection
    end
  end
end
