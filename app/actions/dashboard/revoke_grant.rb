# frozen_string_literal: true

module Kquest
  module Actions
    module Dashboard
      # POST /grants/:grant_id/revoke — REVOKE (I19 Part 2): the grant row
      # selected by (id, owner_user_id) — ANY scope is revocable, the row is
      # the operator's own; a non-owner gets 404 BEFORE any mutation. The
      # door deletes the row — revocation IS row deletion, private = absence
      # (the I02 law); the ladder re-derives on the next read.
      class RevokeGrant < Kquest::Action
        include Kquest::Deps["db.gateway"]

        def handle(req, res)
          user = current_user(req)
          require_login(req, res)

          grant = Kquest::Ui::OperatorWrite.owned_grant!(
            conn, user_id: user.id, grant_id: req.params[:grant_id]
          )
          return halt_not_found(res) unless grant

          Kquest::Ui::OperatorWrite.revoke_grant!(conn, user: {id: user.id,
                                                               username: user.username},
                                                  grant: grant)
          redirect_back_with_flash(req, res, fallback: "/",
                                   notice: "Grant revoked — the source is private again " \
                                           "unless another grant still opens it.")
        end

        private

        def conn = gateway.connection
      end
    end
  end
end
