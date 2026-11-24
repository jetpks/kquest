# frozen_string_literal: true

module Reports
  module Actions
    # POST /quests/:quest_id/report/bind — the operator's BIND (I17 Part 5):
    # through the LANDED report_draft/report_bind tool pair's binding half —
    # the deterministic binding pass over the operator session's draft
    # (citation index → inline ordinals → report_citations rows → footnote
    # block → the standing flip INSIDE the tool's own transaction, I02 §9);
    # the tool's refusals (`hash-transcription`, `import-unmarked`,
    # `ordinal-unbound`) apply verbatim, audited. The landed tool raises a
    # plain ArgumentError when the session has NO draft version — taught here
    # as a 422 with an audited ok=false row (never a 500). OWNER-gated.
    class ReportBind < Kquest::Action
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

        draft = conn[:report_versions]
                .where(quest_id: quest_id, created_session_id: session.fetch(:id))
                .where(bound_at: nil)
                .order(Sequel.desc(:version_seq)).first
        unless draft
          message = "report_bind: no draft version to bind — draft the sections first " \
                    "(the binding pass runs over the session's draft)"
          conn.transaction do
            Kquest::Ui::OperatorWrite.record!(
              conn, session: session, tool: "report_bind", args: {},
              result: {content: message, is_error: true}, ok: false, error_class: "NoDraft"
            )
          end
          halt_unprocessable(res, [message])
        end

        outcome = Kquest::Ui::OperatorWrite.write!(conn, session: session,
                                                   tool_name: "report_bind", args: {})
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
