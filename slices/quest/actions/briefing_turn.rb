# frozen_string_literal: true

module Quest
  module Actions
    # POST /quests/:quest_id/briefing/turns — SUBMIT one operator chat turn
    # (I18 the §8 amendment; Spec Part 2.2): owner gate → the open briefing
    # session is REQUIRED (422 teaching refusal naming the open-session door
    # otherwise) → OperatorWrite.enqueue_turn! (the ONLY [:briefing_turns]
    # writer in the web tree) → PRG redirect back with flash. NO provider
    # machinery, no spawn, no publish anywhere in this path (BRIEF §3
    # zero-auto): the row IS the turn; the WORKER consumes and executes the
    # agent half. The blank-body refusal rides the door's Kquest::Engine::Error
    # (rendered 422 — the briefing_session door's own shape).
    class BriefingTurn < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        quest = Kquest::Ui::OperatorWrite.owner_quest!(conn, user_id: user.id, quest_id: quest_id)
        return halt_not_found(res) unless quest

        session = Kquest::Ui::OperatorWrite.current_session(conn, quest_id: quest_id)
        unless session
          halt_unprocessable(res, ["no open briefing session — open one first (POST " \
                                   "/quests/#{quest_id}/briefing/session); the operator chat " \
                                   "is session-bearing"])
        end

        begin
          Kquest::Ui::OperatorWrite.enqueue_turn!(conn, session: session,
                                                  body: req.params[:body].to_s)
        rescue Kquest::Engine::Error => e
          res.flash["alert"] = e.message
          halt_unprocessable(res, [e.message])
        end
        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/briefing",
                                 notice: "Turn enqueued — the worker picks it up and the " \
                                         "agent replies in the transcript.")
      end

      private

      def conn = gateway.connection
    end
  end
end
