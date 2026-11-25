# frozen_string_literal: true

module Kquest
  module Actions
    module Dashboard
      # POST /grants/public — GRANT PUBLIC (I19 Part 2): the operator's OWN
      # source by (urn, user_id) — the X38 class taught, never 500'd —
      # REQUIRED note, an existing public grant taught. The insert carries
      # is_public: true with BOTH grantee columns NULL — the exactly-one
      # CHECK (ck_resource_grants_grantee_exactly_one) is fixed by the
      # door's own shape, structurally unreachable as a user-facing error.
      class CreatePublicGrant < Kquest::Action
        include Kquest::Deps["db.gateway"]

        def handle(req, res)
          user = current_user(req)
          require_login(req, res)

          begin
            Kquest::Ui::OperatorWrite.create_public_grant!(
              conn, user: {id: user.id, username: user.username},
                    source_urn: req.params[:source_urn].to_s, note: req.params[:note].to_s
            )
          rescue Kquest::Engine::Error => e
            res.flash["alert"] = e.message
            halt_unprocessable(res, [e.message])
          end
          redirect_back_with_flash(
            req, res, fallback: "/",
            notice: "Source #{req.params[:source_urn].to_s.strip} is public — anyone can " \
                    "read it (the global door)."
          )
        end

        private

        def conn = gateway.connection
      end
    end
  end
end
