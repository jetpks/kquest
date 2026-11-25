# frozen_string_literal: true

module Kquest
  module Actions
    module Dashboard
      # POST /workspaces/:workspace_id/grants — GRANT TO WORKSPACE (I19 Part
      # 2): the WORKSPACE owner gate first (granting into a workspace you
      # cannot administer would bypass its owner's member list — 404 non-leak),
      # then the door: the operator's OWN source by (urn, user_id) — the
      # composite-FK X38 class taught, never 500'd — REQUIRED note, duplicate
      # grant taught. The exactly-one grantee shape is fixed by the door's
      # own insert, never user input.
      class CreateWorkspaceGrant < Kquest::Action
        include Kquest::Deps["db.gateway"]

        def handle(req, res)
          user = current_user(req)
          require_login(req, res)

          workspace = Kquest::Ui::OperatorWrite.owned_workspace!(
            conn, user_id: user.id, workspace_id: req.params[:workspace_id]
          )
          return halt_not_found(res) unless workspace

          begin
            Kquest::Ui::OperatorWrite.create_workspace_grant!(
              conn, user: {id: user.id, username: user.username}, workspace: workspace,
                    source_urn: req.params[:source_urn].to_s, note: req.params[:note].to_s
            )
          rescue Kquest::Engine::Error => e
            res.flash["alert"] = e.message
            halt_unprocessable(res, [e.message])
          end
          redirect_back_with_flash(
            req, res, fallback: "/",
            notice: "Source #{req.params[:source_urn].to_s.strip} granted to " \
                    "#{workspace.fetch(:name)} — its members can now read it."
          )
        end

        private

        def conn = gateway.connection
      end
    end
  end
end
