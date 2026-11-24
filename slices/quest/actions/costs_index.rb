# frozen_string_literal: true

module Quest
  module Actions
    # GET /quests/:quest_id/costs — the COST VIEW (I08 §4 row 7 / I16 Part 8,
    # LAST per the in-entry sequencing law). EVERY rollup is REUSED from the
    # Kquest::Orchestrator::Metrics families (one rollup, no second
    # validator); the usage-event ledger listing is capped (L15). Reporting-
    # ONLY: I07 DR-08 verbatim — "these should not bind the operator".
    # NOTHING here throttles, blocks, or links to any enforcement. The live
    # tail rides the EventFeed on the quest stream (spend.tick). Filters
    # (phase/model/window) are server-side query params: the phase filter
    # narrows the reused families' samples (their labels carry phase_id); the
    # model/window filters narrow the ledger listing (the family samples carry
    # no model axis — the ledger is where model filtering is honest).
    class CostsIndex < Kquest::Action
      include Kquest::Deps["db.gateway"]

      COST_PANELS = %w[kquest_closure_economics_cost_per_class kquest_cost_per_claim
                       kquest_cost_per_evidence kquest_metabolism
                       kquest_empty_completion_rate kquest_spend].freeze

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        return halt_not_found(res) unless Kquest::Ui::Visibility.visible_quest?(
          conn, user_id: user.id, quest_id: quest_id
        )
        quest = conn[:quests].where(id: quest_id, user_id: user.id).first

        render_inertia(req, res, "Costs/Index",
                       props: props(user, quest_id, quest, req.params))
      end

      private

      def conn = gateway.connection

      def props(user, quest_id, quest, params)
        {
          panels: panels(user, params),
          ledger: ledger(user, quest_id, params),
          budgets: budgets(quest),
          stream_url: "/quests/#{quest_id}/stream",
          filters: filters(params)
        }
      end

      # The reused Metrics families (one rollup, no second validator), the
      # phase filter narrowing the samples by their phase_id label.
      def panels(user, params)
        phase = params[:phase].to_s
        Kquest::Orchestrator::Metrics.families(conn, user_id: user.id)
                                     .select { |f| COST_PANELS.include?(f[:name]) }
                                     .map do |family|
          next family if phase.empty?

          filtered = family.merge(
            samples: family[:samples].select { |s| s[:labels]["phase_id"] == phase }
          )
          filtered
        end
      end

      # The usage-event ledger (L15): principled order + the config cap +
      # telemetry, with the model/window filters applied.
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

      # The budget lines are ECHOED from the quest's own columns (L9 — the
      # ledger is the counter, never a stored value), never hardcoded.
      def budgets(quest)
        quest ? {web_call_budget: quest.fetch(:web_call_budget),
                 token_budget: quest.fetch(:token_budget),
                 spend_budget_usd: quest.fetch(:spend_budget_usd).to_s("F")} : {}
      end

      def filters(params)
        {phase: params[:phase], model: params[:model],
         window_hours: params[:window_hours]}
      end
    end
  end
end
