# frozen_string_literal: true

module Quest
  module Actions
    # POST /quests/:quest_id/pause — the lifecycle door's PAUSE half (I16
    # Part 1 / D5: pause is the ONLY door while running). The ledgered
    # active → paused transition with the SAME semantics as
    # SessionSupervisor#pause_quest! (lib/kquest/engine/session_supervisor.rb —
    # the supervisor's own refusal is the law; implemented inline here because
    # the supervisor needs the worker-side liveness registry). Refusals are
    # 422 with NO ledger row and NO state change. The launcher owns worker
    # boot — no UI action ever spawns.
    class Pause < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        return halt_not_found(res) unless Kquest::Ui::Visibility.visible_quest?(
          conn, user_id: user.id, quest_id: quest_id
        )

        refusal = nil
        conn.transaction do
          quest = conn[:quests].where(id: quest_id).for_update.first
          if quest.nil? || quest.fetch(:state) != "active"
            refusal = "quest is not active (state #{quest ? quest.fetch(:state).inspect : 'absent'}) " \
                      "— active → paused is a ledgered transition from active"
          else
            conn[:quests].where(id: quest_id).update(state: "paused")
            conn[:quest_lifecycle_events].insert(
              user_id: user.id, quest_id: quest_id,
              from_state: "active", to_state: "paused", actor: "operator",
              occurred_at: Time.now,
              note: "ui pause door — operator #{user.username}"
            )
          end
        end

        # res.redirect_to THROWS :halt — the redirect happens OUTSIDE the
        # transaction block above, never unwinding through it.
        if refusal
          res.flash["alert"] = refusal
          halt_unprocessable(res, [refusal])
        end
        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}",
                                 notice: "Quest paused — steering lands at the pause door.")
      end

      private

      def conn = gateway.connection
    end
  end
end
