# frozen_string_literal: true

require "csv" # the stdlib writer — no gem dependency (the no-new-deps law)

module Quest
  module Actions
    # GET /quests/:quest_id/costs.csv — the cost view's ONE export (I16 Part
    # 8): the same filtered, CAPPED usage-event ledger as the costs page, as
    # text/csv. Reporting-only (I07 DR-08) — the export throttles nothing.
    class CostsExport < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        return halt_not_found(res) unless Kquest::Ui::Visibility.visible_quest?(
          conn, user_id: user.id, quest_id: quest_id
        )

        listing = ledger(user, quest_id, req.params)

        body = CSV.generate do |csv|
          csv << %w[created_at kind model input_tokens output_tokens
                    cache_read_tokens cache_write_tokens cost_usd
                    phase_id session_id]
          listing[:rows].each do |r|
            csv << [r[:created_at]&.utc&.iso8601, r[:kind], r[:model],
                    r[:input_tokens], r[:output_tokens], r[:cache_read_tokens],
                    r[:cache_write_tokens], r[:cost_usd]&.to_s("F"),
                    r[:phase_id], r[:session_id]]
          end
        end

        res.status = 200
        res.headers["content-type"] = "text/csv; charset=utf-8"
        res.headers["content-disposition"] = "attachment; filename=\"costs-#{quest_id}.csv\""
        res.body = body
      end

      private

      def conn = gateway.connection

      # The SAME ledger listing as the costs page (surface "costs", the same
      # model/window filters — the phase filter narrows family samples, not
      # flat rows).
      def ledger(user, quest_id, params)
        dataset = conn[:usage_events].where(quest_id: quest_id)
        model = params[:model].to_s
        dataset = dataset.where(model: model) unless model.empty?
        if (window_h = window_hours(params))
          dataset = dataset.where(Sequel.lit("created_at > now() - (? || ' hours')::interval",
                                             window_h))
        end
        Kquest::Ui::CappedListing.call(
          conn, dataset, surface: "costs", user_id: user.id, quest_id: quest_id,
          order: [Sequel.desc(:created_at), :id]
        )
      end

      # A non-numeric window param is no filter at all — the listing stays.
      def window_hours(params)
        Integer(params[:window_hours].to_s, 10)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
