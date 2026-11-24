# frozen_string_literal: true

module Quest
  module Actions
    # POST /quests/:quest_id/resume — the lifecycle door's RESUME half (I16
    # Part 1): the WEB_BUDGET_RAISE channel's resume half — the ledgered
    # paused → active transition inside a `for_update` transaction, actor
    # 'operator', note recording who/why. NO config change (cap raises are
    # I17's console, operator-in-person) and NO spawn — the launcher boots
    # exactly one worker per ACTIVE quest on its own tick; the ledgered
    # transition is the whole action.
    class Resume < Kquest::Action
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
          if quest.nil? || quest.fetch(:state) != "paused"
            refusal = "quest is not paused (state #{quest ? quest.fetch(:state).inspect : 'absent'}) " \
                      "— paused → active is a ledgered transition from paused"
          else
            conn[:quests].where(id: quest_id).update(state: "active")
            conn[:quest_lifecycle_events].insert(
              user_id: user.id, quest_id: quest_id,
              from_state: "paused", to_state: "active", actor: "operator",
              occurred_at: Time.now,
              note: "ui resume door — operator #{user.username} (no config change; " \
                    "the launcher owns worker boot)"
            )
          end
        end

        # Redirect OUTSIDE the transaction — res.redirect_to throws :halt and
        # must never unwind through a Sequel block.
        if refusal
          res.flash["alert"] = refusal
          halt_unprocessable(res, [refusal])
        end
        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}",
                                 notice: "Quest resumed — the launcher picks it up on its next tick.")
      end

      private

      def conn = gateway.connection
    end
  end
end
