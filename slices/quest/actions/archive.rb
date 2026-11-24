# frozen_string_literal: true

module Quest
  module Actions
    # POST /quests/:quest_id/archive — the lifecycle door's ARCHIVE half (I16
    # Part 1): `complete|stopped → archived` ONLY (the frozen
    # ck_quest_lifecycle_transition), carrying the MANDATORY archive payload —
    # the counts + graph_fingerprint (from v_quest_graph_fingerprint) + the
    # quest's complete verification phase — satisfying the
    # ck_quest_lifecycle_archive_* CHECKs at the DB. Illegal state → 422, no
    # ledger row, no state change. No other table is touched: quests.state +
    # the lifecycle ledger ARE the record (I08 §5.2 "not a second ledger").
    class Archive < Kquest::Action
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
          unless quest && %w[complete stopped].include?(quest.fetch(:state))
            refusal = "quest is not complete or stopped " \
                      "(state #{quest ? quest.fetch(:state).inspect : 'absent'}) — " \
                      "archived is a ledgered transition from complete or stopped"
            next
          end

          vphase = conn[:phases].where(quest_id: quest_id, kind: "verification", state: "complete")
                                .order(Sequel.desc(:created_at), Sequel.desc(:id)).first
          unless vphase
            refusal = "no complete verification phase — the archive payload REQUIRES " \
                      "verification_phase_id (ck_quest_lifecycle_archive_pair)"
            next
          end

          conn[:quests].where(id: quest_id).update(state: "archived")
          conn[:quest_lifecycle_events].insert(
            user_id: user.id, quest_id: quest_id,
            from_state: quest.fetch(:state), to_state: "archived", actor: "operator",
            verification_phase_id: vphase.fetch(:id),
            claims_at_archive: conn[:claims].where(quest_id: quest_id).count,
            evidence_at_archive: conn[:evidence].where(quest_id: quest_id).count,
            frontier_open_at_archive: conn[:frontier_entries].where(quest_id: quest_id, state: "open").count,
            graph_fingerprint: conn[:v_quest_graph_fingerprint].where(quest_id: quest_id)
                                                               .get(:graph_fingerprint),
            occurred_at: Time.now,
            note: "ui archive door — operator #{user.username}"
          )
        end

        # Redirect OUTSIDE the transaction — res.redirect_to throws :halt and
        # must never unwind through a Sequel block.
        if refusal
          res.flash["alert"] = refusal
          halt_unprocessable(res, [refusal])
        end
        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}",
                                 notice: "Quest archived — the archive payload is ledgered.")
      end

      private

      def conn = gateway.connection
    end
  end
end
