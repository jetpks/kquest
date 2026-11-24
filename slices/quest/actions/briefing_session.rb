# frozen_string_literal: true

module Quest
  module Actions
    # POST /quests/:quest_id/briefing/session — OPEN the briefing session
    # (I17 Part 3 / I06 §8): OperatorWrite.open_session! — the LANDED launch
    # gate (mode `interactive`, driver `operator`, the decompose round-1
    # mint per I01 DR-13). This is the operator SEIZING the write gate (L13
    # one-active-writer): on an `active` quest the worker's autonomous launch
    # is refused naming this holder — the law working as designed (Grounds
    # §6.8). A live holder → the supervisor's FROZEN refusal rendered 422,
    # verbatim.
    class BriefingSession < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        quest = Kquest::Ui::OperatorWrite.owner_quest!(conn, user_id: user.id, quest_id: quest_id)
        return halt_not_found(res) unless quest

        begin
          Kquest::Ui::OperatorWrite.open_session!(conn, user: {id: user.id, username: user.username},
                                                  quest: quest)
        rescue Kquest::Engine::Error => e
          res.flash["alert"] = e.message
          halt_unprocessable(res, [e.message])
        end
        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/briefing",
                                 notice: "Briefing session open — the operator holds the write gate.")
      end

      private

      def conn = gateway.connection
    end
  end
end
