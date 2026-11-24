# frozen_string_literal: true

module Watch
  module Actions
    # GET /metrics — the Prometheus text-exposition shape over the durable
    # ledgers (I07 §5, the no-gem ruling). AUTHENTICATED (the app's standard
    # session posture — the recorded ruling: the label axes carry quest/user/
    # session ids; no unauthenticated internal-data surface ships day one;
    # scraper access is a gateway/allowlist decision at deploy, I08 §6).
    class Metrics < Kquest::StreamAction
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        unless user
          res.status = 403
          res.content_type = JSON_CONTENT_TYPE
          res.body = JSON.generate(error: "Forbidden")
          return
        end

        res.status = 200
        res.headers["content-type"] = "text/plain; version=0.0.4; charset=utf-8"
        res.body = Kquest::Orchestrator::Metrics.render(conn, user_id: user.id)
      end

      private

      def conn = gateway.connection
    end
  end
end
