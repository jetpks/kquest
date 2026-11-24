# frozen_string_literal: true

module Reports
  module Actions
    # GET /quests/:quest_id/report/versions/:version_seq/body — the ONE
    # read-only action on the report view (I16 Part 7): the body blob streamed
    # as an attachment THROUGH THE UPLOADER SEAM — the store address is
    # BlobUploader.location_for(:report, report_version_id:) (the DB column's
    # body_blob_key is CHECK-law bookkeeping, NOT the store address; the
    # report_draft tool's own read_body is the pattern). Draft/bind/flip/
    # import-mark are I17's.
    class ReportBody < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        return halt_not_found(res) unless Kquest::Ui::Visibility.visible_quest?(
          conn, user_id: user.id, quest_id: quest_id
        )

        version_seq = Integer(req.params[:version_seq].to_s, 10)
        version = conn[:report_versions].where(quest_id: quest_id, version_seq: version_seq).first
        return halt_not_found(res) unless version

        body = Kquest::BlobUploader.uploaded_file(
          JSON.generate({"id" => Kquest::BlobUploader.location_for(
            :report, report_version_id: version.fetch(:id)
          ), "storage" => "store"})
        ).read

        res.status = 200
        res.headers["content-type"] = "text/markdown; charset=utf-8"
        res.headers["content-disposition"] =
          "attachment; filename=\"report-#{quest_id}-v#{version_seq}.md\""
        res.body = body
      rescue ArgumentError, TypeError
        halt_not_found(res)
      end

      private

      def conn = gateway.connection
    end
  end
end
