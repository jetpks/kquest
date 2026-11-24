# frozen_string_literal: true

module Quest
  module Actions
    # POST /quests/:quest_id/console/session/end — the operator attach end
    # (I17 Part 2) and the briefing's SIGN-OFF (Part 3 / DR-04 ruling A: the
    # operator ends the briefing session; the orchestrator resumes
    # autonomously). OperatorWrite.end_session! stamps `sessions.ended_at`
    # ONLY (the session's own audit is the record — no lifecycle row: no
    # transition occurred); 422 with the teaching refusal when no open
    # operator session exists.
    class ConsoleSessionEnd < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        return halt_not_found(res) unless Kquest::Ui::OperatorWrite.owner_quest!(
          conn, user_id: user.id, quest_id: quest_id
        )

        begin
          Kquest::Ui::OperatorWrite.end_session!(conn, quest_id: quest_id)
        rescue Kquest::Engine::Error => e
          res.flash["alert"] = e.message
          halt_unprocessable(res, [e.message])
        end
        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/briefing",
                                 notice: "Session ended — the sign-off is the record " \
                                         "(DR-04 ruling A: autonomy resumes).")
      end

      private

      def conn = gateway.connection
    end
  end
end
