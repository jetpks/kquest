# frozen_string_literal: true

module Quest
  module Actions
    # POST /quests/:quest_id/console/stop — the steering door's STOP half
    # (I17 Part 2): `paused → stopped` ONLY (the menus' stop disposition —
    # the budget/slow-stall/stop-loud "stop" option rides THIS door). ONE
    # for_update transaction, ONE quest_lifecycle_events row (actor
    # 'operator', note naming the door + the operator + their why); 422 on
    # any other state, NO row, NO state change. No config edits ride the
    # stop door (an override rides resume/restart — Grounds §6.2).
    class ConsoleStop < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        return halt_not_found(res) unless Kquest::Ui::OperatorWrite.owner_quest!(
          conn, user_id: user.id, quest_id: quest_id
        )

        refusal = nil
        conn.transaction do
          quest = conn[:quests].where(id: quest_id).for_update.first
          if quest.nil? || quest.fetch(:state) != "paused"
            refusal = "quest is not paused (state #{quest ? quest.fetch(:state).inspect : 'absent'}) " \
                      "— the stop door is the ledgered paused → stopped pair"
          else
            conn[:quests].where(id: quest_id).update(state: "stopped")
            why = req.params[:note].to_s.strip
            note = "ui console stop door — operator #{user.username}"
            note += " — why: #{why}" unless why.empty?
            conn[:quest_lifecycle_events].insert(
              user_id: user.id, quest_id: quest_id,
              from_state: "paused", to_state: "stopped", actor: "operator",
              occurred_at: Time.now, note: note
            )
          end
        end

        # Redirect OUTSIDE the transaction — res.redirect_to throws :halt and
        # must never unwind through a Sequel block.
        if refusal
          res.flash["alert"] = refusal
          halt_unprocessable(res, [refusal])
        end
        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/console",
                                 notice: "Quest stopped — restart is the ledgered stopped → active pair.")
      end

      private

      def conn = gateway.connection
    end
  end
end
