# frozen_string_literal: true

module Kquest
  module Actions
    module Dashboard
      # POST /workspaces — CREATE WORKSPACE (I19 Part 2): the workspace-admin
      # door into OperatorWrite.create_workspace! — the workspaces row AND
      # the creator's membership row in ONE transaction (the frozen I02
      # fixture shape: the creator IS a member). Teaching refusals (blank /
      # slug law / global uniqueness) render 422; the DB CHECKs
      # (ck_workspaces_name, uq_workspaces_name) are the backstop, never the
      # user-facing error. Zero-auto: no worker, no provider machinery.
      class CreateWorkspace < Kquest::Action
        include Kquest::Deps["db.gateway"]

        def handle(req, res)
          user = current_user(req)
          require_login(req, res)

          begin
            workspace = Kquest::Ui::OperatorWrite.create_workspace!(
              conn, user: {id: user.id, username: user.username},
                    name: req.params[:name].to_s
            )
          rescue Kquest::Engine::Error => e
            res.flash["alert"] = e.message
            halt_unprocessable(res, [e.message])
          end
          redirect_back_with_flash(req, res, fallback: "/",
                                   notice: "Workspace #{workspace.fetch(:name)} created — " \
                                           "you are its first member.")
        end

        private

        def conn = gateway.connection
      end
    end
  end
end
