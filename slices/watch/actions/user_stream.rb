# frozen_string_literal: true

module Watch
  module Actions
    # GET /alerts/stream — the USER-level SSE serving action (I08 §3.1's gap /
    # I16 Part 4): the I15 EventPublisher producer (#publish_user, key
    # `kquest:sse:user:<uuid>`) finally has its server. The adopted
    # backlog-then-live transport via Kquest::StreamAction; the gate runs
    # FIRST (unauthenticated → 403 JSON BEFORE any SSE header — once the SSE
    # headers are set, an error can only surface as a broken stream). The
    # I15 frozen contract (`/quests/:quest_id/stream`, `/metrics`) is
    # untouched.
    class UserStream < Kquest::StreamAction
      def handle(req, res)
        user = current_user(req)
        unless user
          res.status = 403
          res.content_type = JSON_CONTENT_TYPE
          res.body = JSON.generate(error: "Forbidden")
          return
        end

        render_stream(req, res, key: "kquest:sse:user:#{user.id}")
      end
    end
  end
end
