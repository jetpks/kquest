# frozen_string_literal: true

require "csv" # the stdlib writer — no gem dependency (the no-new-deps law)

module Graph
  module Actions
    # GET /quests/:quest_id/frontier.csv — the frontier inspector's ONE
    # read-only export (I16 Part 5): a text/csv SNAPSHOT of the same capped
    # listing (mass order, the config cap — the export never exceeds what the
    # inspector shows). No write door exists on this surface.
    class FrontierExport < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        return halt_not_found(res) unless Kquest::Ui::Visibility.visible_quest?(
          conn, user_id: user.id, quest_id: quest_id
        )

        listing = Kquest::Ui::CappedListing.call(
          conn, conn[:v_frontier_open].where(quest_id: quest_id),
          surface: "frontier", user_id: user.id, quest_id: quest_id,
          order: [Sequel.desc(:mass), :entry_id]
        )

        body = CSV.generate do |csv|
          csv << %w[entry_id claim_seq need uncertainty relevance mass opened_at]
          listing[:rows].each do |r|
            csv << [r[:entry_id], r[:claim_seq], r[:need], r[:uncertainty],
                    r[:relevance], r[:mass], r[:opened_at]&.utc&.iso8601]
          end
        end

        res.status = 200
        res.headers["content-type"] = "text/csv; charset=utf-8"
        res.headers["content-disposition"] =
          "attachment; filename=\"frontier-#{quest_id}.csv\""
        res.body = body
      end

      private

      def conn = gateway.connection
    end
  end
end
