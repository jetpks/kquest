# frozen_string_literal: true

module Kquest
  module Actions
    module Dashboard
      # POST /workspaces/:workspace_id/members — ADD MEMBER (I19 Part 2): the
      # owner gate first (404 non-leak), then the door adds by users.handle —
      # unknown handle / duplicate membership taught 422 (pk_workspace_members
      # is the backstop). joined_at defaults now — the membership write's
      # when-carrier.
      class AddWorkspaceMember < Kquest::Action
        include Kquest::Deps["db.gateway"]

        def handle(req, res)
          user = current_user(req)
          require_login(req, res)

          workspace = Kquest::Ui::OperatorWrite.owned_workspace!(
            conn, user_id: user.id, workspace_id: req.params[:workspace_id]
          )
          return halt_not_found(res) unless workspace

          begin
            Kquest::Ui::OperatorWrite.add_workspace_member!(
              conn, user: {id: user.id, username: user.username}, workspace: workspace,
                    handle: req.params[:handle].to_s
            )
          rescue Kquest::Engine::Error => e
            res.flash["alert"] = e.message
            halt_unprocessable(res, [e.message])
          end
          redirect_back_with_flash(req, res, fallback: "/",
                                   notice: "#{req.params[:handle].to_s.strip} is now a member " \
                                           "of #{workspace.fetch(:name)}.")
        end

        private

        def conn = gateway.connection
      end
    end
  end
end
