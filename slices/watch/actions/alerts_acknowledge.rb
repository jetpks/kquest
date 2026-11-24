# frozen_string_literal: true

module Watch
  module Actions
    # POST /alerts/acknowledge — the alerting surface's ONE write (I16 Part 2):
    # a UI state ONLY — flash/session, writing NOTHING to PG (the map's own
    # law: "a UI state, never a system state"). No DB handle exists on this
    # action — that absence is the law, wired. The mute is I17's (ALL
    # config-row writes concentrate there).
    class AlertsAcknowledge < Kquest::Action
      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        predicate = req.params[:predicate].to_s
        acks = req.session[:acknowledged_alerts] ||= {}
        acks[predicate] = Time.now.utc.to_s

        res.flash["notice"] =
          "Acknowledged #{predicate} — a UI state only: the ledger rows and the views are untouched."
        redirect_back_with_flash(req, res, fallback: "/alerts")
      end
    end
  end
end
