# frozen_string_literal: true

module Kquest
  module Actions
    module Dashboard
      # POST /workspaces/:workspace_id/members/remove — REMOVE MEMBER (I19
      # Part 2): the owner gate first (404 non-leak), then the door deletes
      # the membership row — not-a-member taught 422 ("nothing to remove",
      # the mute-remove shape). Removing the creator's own membership is
      # lawful (created_by admin rights are unaffected).
      class RemoveWorkspaceMember < Kquest::Action
        include Kquest::Deps["db.gateway"]

        def handle(req, res)
          user = current_user(req)
          require_login(req, res)

          workspace = Kquest::Ui::OperatorWrite.owned_workspace!(
            conn, user_id: user.id, workspace_id: req.params[:workspace_id]
          )
          return halt_not_found(res) unless workspace

          begin
            Kquest::Ui::OperatorWrite.remove_workspace_member!(
              conn, user: {id: user.id, username: user.username}, workspace: workspace,
                    handle: req.params[:handle].to_s
            )
          rescue Kquest::Engine::Error => e
            res.flash["alert"] = e.message
            halt_unprocessable(res, [e.message])
          end
          redirect_back_with_flash(req, res, fallback: "/",
                                   notice: "#{req.params[:handle].to_s.strip} removed from " \
                                           "#{workspace.fetch(:name)}.")
        end

        private

        def conn = gateway.connection
      end
    end
  end
end
