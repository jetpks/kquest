# frozen_string_literal: true

module Kquest
  module Actions
    module Dashboard
      # POST /workspaces/:workspace_id/rename — RENAME WORKSPACE (I19 Part 2):
      # the owner gate selects by (id, created_by_user_id) — a non-owner gets
      # 404 BEFORE any mutation (existence never leaked); the door teaches
      # blank / slug law / global uniqueness (excluding this workspace's own
      # id) as 422, never a CHECK 500.
      class RenameWorkspace < Kquest::Action
        include Kquest::Deps["db.gateway"]

        def handle(req, res)
          user = current_user(req)
          require_login(req, res)

          workspace = Kquest::Ui::OperatorWrite.owned_workspace!(
            conn, user_id: user.id, workspace_id: req.params[:workspace_id]
          )
          return halt_not_found(res) unless workspace

          begin
            renamed = Kquest::Ui::OperatorWrite.rename_workspace!(
              conn, user: {id: user.id, username: user.username}, workspace: workspace,
                    name: req.params[:name].to_s
            )
          rescue Kquest::Engine::Error => e
            res.flash["alert"] = e.message
            halt_unprocessable(res, [e.message])
          end
          redirect_back_with_flash(req, res, fallback: "/",
                                   notice: "Workspace renamed to #{renamed.fetch(:name)}.")
        end

        private

        def conn = gateway.connection
      end
    end
  end
end
