# frozen_string_literal: true

module Reports
  module Actions
    # POST /quests/:quest_id/report/versions/:version_seq/flip — the STANDING
    # FLIP (I17 Part 5; I02 §7 names this entry: "the finalization
    # transaction flips the new version's flag and clears the old"). ONE
    # transaction: the target must be THIS quest's AND `bound_at` present (a
    # draft cannot stand — the teaching refusal); clear the current standing
    # row, set the target's `standing: true` (the partial-unique
    # uq_report_versions_one_standing owns the one-pointer law). Audit via
    # OperatorWrite.record! (tool `report_flip`, the old→new pair recorded).
    # A target that already stands refuses (teaching) — there is nothing to
    # flip. OWNER-gated.
    class ReportFlip < Kquest::Action
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

        seq = begin
          Integer(req.params[:version_seq].to_s, 10)
        rescue ArgumentError, TypeError
          halt_unprocessable(res, ["version_seq is an integer — got #{req.params[:version_seq].inspect}"])
        end
        target = conn[:report_versions]
                 .where(quest_id: quest_id, version_seq: seq).first
        if target.nil?
          halt_unprocessable(res, ["no version #{req.params[:version_seq]} on this quest — the " \
                                   "version chain is the report view's own listing"])
        end
        unless target.fetch(:bound_at)
          halt_unprocessable(res, ["version #{target.fetch(:version_seq)} is a DRAFT — a draft " \
                                   "cannot stand; bind it first (the standing flag rides the " \
                                   "binding pass)"])
        end
        if target.fetch(:standing)
          halt_unprocessable(res, ["version #{target.fetch(:version_seq)} already stands — the " \
                                   "pointer is already on it"])
        end

        previous = conn[:report_versions].where(quest_id: quest_id, standing: true).first
        conn.transaction do
          conn[:report_versions].where(quest_id: quest_id, standing: true).update(standing: false)
          conn[:report_versions].where(id: target.fetch(:id)).update(standing: true)
          Kquest::Ui::OperatorWrite.record!(
            conn, session: session, tool: "report_flip",
            args: {version_seq: target.fetch(:version_seq)},
            result: {content: "standing flipped: " +
                              (previous ? "v#{previous.fetch(:version_seq)}" : "none") +
                              " → v#{target.fetch(:version_seq)}", is_error: false},
            ok: true
          )
        end

        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/report",
                                 notice: "Version #{target.fetch(:version_seq)} stands " \
                                         "(was #{previous ? "v#{previous.fetch(:version_seq)}" : 'none'}).")
      end

      private

      def conn = gateway.connection
    end
  end
end
