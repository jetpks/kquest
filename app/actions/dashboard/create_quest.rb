# frozen_string_literal: true

module Kquest
  module Actions
    module Dashboard
      # POST /quests — CREATE QUEST (I16 Part 3): the pre-briefing form
      # (topic + budgets + routing map) into a `quests` row — state `active`,
      # provenance `fresh`, process_config/model_config from the form's
      # routing map. It creates the ROW ONLY: no session, no worker, no
      # briefing (the interactive briefing is I17's console half; the
      # launcher owns worker boot and finds the quest on its own tick).
      class CreateQuest < Kquest::Action
        include Kquest::Deps["db.gateway"]

        def handle(req, res)
          user = current_user(req)
          require_login(req, res)

          errors = []
          topic = req.params[:topic].to_s.strip
          errors << "topic is required" if topic.empty?

          web_call_budget = budget(req.params[:web_call_budget], "web_call_budget", errors)
          token_budget = budget(req.params[:token_budget], "token_budget", errors)
          spend_budget_usd = spend_budget(req.params[:spend_budget_usd], errors)
          model_config = config_param(req.params[:model_config], "model_config", errors)
          process_config = config_param(req.params[:process_config], "process_config", errors)

          return halt_unprocessable(res, errors) unless errors.empty?

          quest_id = conn[:quests].insert(
            user_id: user.id, topic: topic, state: "active", provenance_kind: "fresh",
            web_call_budget: web_call_budget, token_budget: token_budget,
            spend_budget_usd: spend_budget_usd,
            model_config: Sequel.lit("?::jsonb", JSON.generate(model_config)),
            process_config: Sequel.lit("?::jsonb", JSON.generate(process_config))
          )
          redirect_with_flash(res, "/quests/#{quest_id}",
                              notice: "Quest created (row only) — the briefing is I17's console.")
        end

        private

        def conn = gateway.connection

        def budget(raw, name, errors)
          Integer(raw.to_s, 10)
        rescue ArgumentError, TypeError
          errors << "#{name} must be an integer"
          0
        end

        def spend_budget(raw, errors)
          BigDecimal(raw.to_s)
        rescue ArgumentError, TypeError
          errors << "spend_budget_usd must be a decimal"
          BigDecimal("0")
        end

        # The routing map rides the form as a JSON object string; a missing
        # field is the empty map (the quests row's own default).
        def config_param(raw, name, errors)
          return {} if raw.nil? || raw.to_s.strip.empty?

          parsed = JSON.parse(raw.to_s)
          raise TypeError unless parsed.is_a?(Hash)

          parsed
        rescue JSON::ParserError, TypeError
          errors << "#{name} must be a JSON object"
          {}
        end
      end
    end
  end
end
