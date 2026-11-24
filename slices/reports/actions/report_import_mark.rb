# frozen_string_literal: true

module Reports
  module Actions
    # POST /quests/:quest_id/report/versions/:version_seq/citations/:ordinal/
    # import — the EXPLICIT import mark (I17 Part 5; BRIEF D3: "explicitly
    # marked imports — never silently"). ONE transaction: the version must be
    # this quest's; the source must resolve to the operator's OWN citable
    # source (the conditional FK `fk_report_citations_imported_source` has no
    # tenancy pin — it is fetch-time-validated HERE, I02 §3.4); the origin
    # quest must be the SAME user's (the same-user day-one posture, taught);
    # a citation row already bound for this ordinal refuses (the
    # uq_report_citations_ordinal law — the in-corpus XOR case
    # ck_report_citations_resource_exactly_one taught); the import-shaped
    # `report_citations` row lands (`imported: true`, `imported_source_id`,
    # `import_source_quest_id` — the `ck_report_citations_import_pair` law) +
    # the audit row (tool `report_import_mark`). OWNER-gated.
    class ReportImportMark < Kquest::Action
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

        version_seq = begin
          Integer(req.params[:version_seq].to_s, 10)
        rescue ArgumentError, TypeError
          halt_unprocessable(res, ["version_seq is an integer — got #{req.params[:version_seq].inspect}"])
        end
        ordinal = begin
          Integer(req.params[:ordinal].to_s, 10)
        rescue ArgumentError, TypeError
          halt_unprocessable(res, ["ordinal is an integer — got #{req.params[:ordinal].inspect}"])
        end
        halt_unprocessable(res, ["the ordinal is ≥ 1 (the CHECK law) — got #{ordinal}"]) if ordinal < 1

        source_urn = req.params[:source_urn].to_s.strip
        origin_quest_id = req.params[:origin_quest_id].to_s.strip
        halt_unprocessable(res, ["a source_urn and an origin_quest_id are each required — the " \
                                 "import is EXPLICIT (never silent)"]) if source_urn.empty? || origin_quest_id.empty?

        version = conn[:report_versions].where(quest_id: quest_id, version_seq: version_seq).first
        unless version
          halt_unprocessable(res, ["no version #{version_seq} on this quest — the import marks " \
                                   "THIS quest's bound chain"])
        end

        source = conn[:sources].where(user_id: user.id, urn: source_urn, role: "citable").first
        unless source
          halt_unprocessable(res, ["the import source must resolve to YOUR OWN citable source " \
                                   "by urn — the conditional FK carries no tenancy pin, so the " \
                                   "check is fetch-time-validated here"])
        end

        origin = conn[:quests].where(id: origin_quest_id, user_id: user.id).first
        unless origin
          halt_unprocessable(res, ["the origin quest must be YOURS (the same-user day-one " \
                                   "posture) — got #{origin_quest_id}"])
        end

        existing = conn[:report_citations]
                   .where(report_version_id: version.fetch(:id), ordinal: ordinal).first
        if existing
          halt_unprocessable(res, ["ordinal [^#{ordinal}] is already bound on version " \
                                   "#{version_seq} (#{
                                     existing.fetch(:imported) ? 'an import row' : 'in-corpus'
                                   }) — a version carries exactly one citation row per ordinal " \
                                   "(the XOR law: in-corpus XOR import)"])
        end

        conn.transaction do
          conn[:report_citations].insert(
            user_id: user.id, quest_id: quest_id, report_version_id: version.fetch(:id),
            ordinal: ordinal, source_id: nil,
            imported: true, imported_source_id: source.fetch(:id),
            import_source_quest_id: origin.fetch(:id)
          )
          Kquest::Ui::OperatorWrite.record!(
            conn, session: session, tool: "report_import_mark",
            args: {version_seq: version_seq, ordinal: ordinal, source_urn: source_urn,
                   origin_quest_id: origin.fetch(:id)},
            result: {content: "[^#{ordinal}] on v#{version_seq} marked an import of " \
                              "#{source_urn} (origin #{origin.fetch(:id)})", is_error: false},
            ok: true
          )
        end

        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/report",
                                 notice: "[^#{ordinal}] marked an explicit import of #{source_urn}.")
      end

      private

      def conn = gateway.connection
    end
  end
end
