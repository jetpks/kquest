# frozen_string_literal: true

module Reports
  module Actions
    # POST /quests/:quest_id/report/draft — the operator's SECTION DRAFT (I17
    # Part 5 / L13: same tools, same constraints, same audit): through
    # OperatorWrite.write!(tool_name: "report_draft", …) with params version
    # (optional) + section + body — the LANDED tool's own draft-version law
    # (bound versions frozen — a rework is a NEW draft version) and refusals
    # (`version-frozen`, `section-too-large`) apply verbatim; audited both
    # sides. Opens/reuses the operator session on demand. OWNER-gated.
    class ReportDraft < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        quest = Kquest::Ui::OperatorWrite.owner_quest!(conn, user_id: user.id, quest_id: quest_id)
        return halt_not_found(res) unless quest

        section = req.params[:section].to_s.strip
        body = req.params[:body].to_s
        if section.empty? || body.empty?
          halt_unprocessable(res, ["a section key and a body are each required — the draft " \
                                   "accumulates CHECK-nonempty sections"])
        end

        session = Kquest::Ui::OperatorWrite.open_session!(
          conn, user: {id: user.id, username: user.username}, quest: quest
        )

        args = {section: section, body: body}
        version = req.params[:version].to_s.strip
        unless version.empty?
          # An EXPLICIT target names an EXISTING version on the quest's chain
          # (the landed tool's version-frozen refusal still applies verbatim
          # for a BOUND one; an unknown target teaches HERE — never a 500).
          seq = begin
            Integer(version, 10)
          rescue ArgumentError, TypeError
            halt_unprocessable(res, ["version names a version_seq on the quest's chain — got #{version.inspect}"])
          end
          target = conn[:report_versions].where(quest_id: quest_id, version_seq: seq).first
          halt_unprocessable(res, ["no version #{seq} on this quest's chain — the version " \
                                   "view's chain is the listing"]) unless target
          args[:version] = version
        end

        outcome = Kquest::Ui::OperatorWrite.write!(conn, session: session,
                                                   tool_name: "report_draft", args: args)
        unless outcome.fetch(:ok)
          res.flash["alert"] = outcome.fetch(:outcome)
          halt_unprocessable(res, [outcome.fetch(:outcome)])
        end
        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/report",
                                 notice: outcome.fetch(:outcome))
      end

      private

      def conn = gateway.connection
    end
  end
end
