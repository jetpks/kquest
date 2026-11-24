# frozen_string_literal: true

module Graph
  module Actions
    # POST /quests/:quest_id/graph/conflicts/:conflict_id/hypothesis —
    # HYPOTHESIZE/ADJUDICATE (I17 Part 4): set `resolution_hypothesis`
    # (non-empty — the CHECK law `ck_conflicts_hypothesis_nonempty`) on the
    # quest's conflict row + the OperatorWrite.record! audit (tool
    # `conflict_hypothesis`); 422 on an unknown/foreign conflict or a blank
    # hypothesis — teaching, no partial write. Session-bearing (the audit
    # rides the operator session opened on demand).
    class ConflictHypothesis < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        quest = Kquest::Ui::OperatorWrite.owner_quest!(conn, user_id: user.id, quest_id: quest_id)
        return halt_not_found(res) unless quest

        session = Kquest::Ui::OperatorWrite.open_session!(
          conn, user: {id: user.id, username: user.username}, quest: quest
        )

        hypothesis = req.params[:hypothesis].to_s.strip
        if hypothesis.empty?
          halt_unprocessable(res, ["the hypothesis is non-empty (the CHECK law) — a blank " \
                                   "adjudication teaches the form, it never writes"])
        end

        conflict = conn[:conflicts].where(id: req.params[:conflict_id], quest_id: quest_id).first
        unless conflict
          halt_unprocessable(res, ["no such conflict on this quest — the docket's rows are the " \
                                   "browser's own listing"])
        end

        conn.transaction do
          conn[:conflicts].where(id: conflict.fetch(:id))
                          .update(resolution_hypothesis: hypothesis)
          Kquest::Ui::OperatorWrite.record!(
            conn, session: session, tool: "conflict_hypothesis",
            args: {conflict: conflict.fetch(:id), divergence: conflict.fetch(:divergence)},
            result: {content: "hypothesis recorded on #{conflict.fetch(:id)}", is_error: false},
            ok: true
          )
        end

        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/graph",
                                 notice: "Hypothesis recorded — the docket carries the adjudication.")
      end

      private

      def conn = gateway.connection
    end
  end
end
