# frozen_string_literal: true

require "json"

module Quest
  module Actions
    # POST /quests/:quest_id/console/restart — the steering door's RESTART
    # half (I17 Part 2): `stopped → active` (the graph_invalid repair
    # precedent — I02's ledgered pair), carrying the SAME recorded-merge
    # params as the steering resume: only-raise budgets ("a cap may only
    # RAISE on resume", I06 §6.2 — the law names the resume-shaped doors),
    # shallow jsonb config merges, a REQUIRED note on change. ONE
    # for_update transaction, ONE quest_lifecycle_events row (actor
    # 'operator', the note recording the door + every changed key from→to +
    # who/why); refusals 422 with NO row; a live operator session holding
    # the quest refuses 422 naming the holder. NO spawn (the launcher owns
    # boot) — the recorded transition is the whole action.
    class ConsoleRestart < Kquest::Action
      include Kquest::Deps["db.gateway"]

      PHASE_KINDS = %w[decompose frontier-build descent synthesis verification].freeze

      # Raised INSIDE the transaction before any write — the teaching 422.
      class Refusal < StandardError; end

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        return halt_not_found(res) unless Kquest::Ui::OperatorWrite.owner_quest!(
          conn, user_id: user.id, quest_id: quest_id
        )

        refusal = nil
        conn.transaction do
          quest = conn[:quests].where(id: quest_id).for_update.first
          if quest.nil? || quest.fetch(:state) != "stopped"
            refusal = "quest is not stopped (state #{quest ? quest.fetch(:state).inspect : 'absent'}) " \
                      "— the restart door is the ledgered stopped → active pair"
          elsif (holder = live_holder(quest_id))
            refusal = holder_refusal(quest_id, holder)
          else
            begin
              refusal = validate(req)
              next if refusal

              changes = []
              apply_budget_raises!(quest, req, changes)
              apply_config_merges!(quest, req, changes)
              conn[:quests].where(id: quest_id).update(state: "active")
              conn[:quest_lifecycle_events].insert(
                user_id: user.id, quest_id: quest_id,
                from_state: "stopped", to_state: "active", actor: "operator",
                occurred_at: Time.now, note: ledger_note(user, req, changes)
              )
            rescue Refusal => e
              refusal = e.message
            end
          end
        end

        # Redirect OUTSIDE the transaction — res.redirect_to throws :halt and
        # must never unwind through a Sequel block.
        if refusal
          res.flash["alert"] = refusal
          halt_unprocessable(res, [refusal])
        end
        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/console",
                                 notice: "Restarted — the launcher picks it up on its next tick.")
      end

      private

      def conn = gateway.connection

      def live_holder(quest_id)
        Kquest::Engine::SessionSupervisor.new(conn: conn).live_holder(quest_id)
      end

      def holder_refusal(quest_id, holder)
        Kquest::Engine::SessionSupervisor.new(conn: conn).write_guard_refusal(
          quest_id: quest_id, session_id: holder[:id], driver: holder[:driver]
        ) + " — end the session first (the hand-off is explicit)"
      end

      # The SAME param law as the steering resume (teaching, no writes).
      def validate(req)
        overrides_present = budget_present?(req, "web_call_budget") ||
                            budget_present?(req, "token_budget") ||
                            spend_present?(req) ||
                            parse_json_object(req, :process_config) ||
                            parse_json_object(req, :model_config)
        return "a note is required whenever an override is present — the ledger records who/why" \
          if overrides_present && req.params[:note].to_s.strip.empty?

        %w[web_call_budget token_budget].each do |name|
          next unless budget_present?(req, name)

          Integer(param(req, name).to_s, 10)
        rescue ArgumentError, TypeError
          return "#{name} must be an integer"
        end
        if spend_present?(req)
          begin
            BigDecimal(param(req, :spend_budget_usd).to_s)
          rescue ArgumentError, TypeError
            return "spend_budget_usd must be a decimal"
          end
        end
        %i[process_config model_config].each do |name|
          next unless param(req, name) && !param(req, name).to_s.strip.empty?

          return "#{name} must be a JSON object" if parse_json_object(req, name).nil?
        end
        validate_model_config(parse_json_object(req, :model_config))
      end

      def validate_model_config(merge)
        return nil unless merge

        merge.each do |kind, model|
          unless PHASE_KINDS.include?(kind.to_s)
            return "model_config keys are phase kinds (#{PHASE_KINDS.join(', ')}) — got #{kind}"
          end
          return "model_config values are non-empty strings — got #{kind}=#{model.inspect}" \
            unless model.is_a?(String) && !model.strip.empty?
        end
        nil
      end

      # Hanami params are symbol-keyed; the symbol-else-string read keeps the
      # helpers honest for both spellings.
      def param(req, key)
        req.params[key.to_sym] || req.params[key.to_s]
      end

      def budget_present?(req, name)
        !param(req, name).nil? && !param(req, name).to_s.strip.empty?
      end

      def spend_present?(req)
        !param(req, :spend_budget_usd).nil? && !param(req, :spend_budget_usd).to_s.strip.empty?
      end

      def parse_json_object(req, name)
        raw = param(req, name)
        return nil if raw.nil? || raw.to_s.strip.empty?

        parsed = JSON.parse(raw.to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      def apply_budget_raises!(quest, req, changes)
        raises = {}
        %w[web_call_budget token_budget].each do |param|
          next unless budget_present?(req, param)

          current = quest.fetch(param.to_sym)
          proposed = Integer(param(req, param).to_s, 10)
          unless proposed > current
            raise Refusal, "#{param} is #{current} — a cap may only RAISE on resume (I06 §6.2)"
          end
          raises[param.to_sym] = proposed
          changes << "#{param} #{current}→#{proposed}"
        end
        if spend_present?(req)
          current = quest.fetch(:spend_budget_usd)
          proposed = BigDecimal(param(req, :spend_budget_usd).to_s)
          unless proposed > current
            raise Refusal, "spend_budget_usd is #{current.to_s('F')} — " \
                           "a cap may only RAISE on resume (I06 §6.2)"
          end
          raises[:spend_budget_usd] = proposed
          changes << "spend_budget_usd #{current.to_s('F')}→#{proposed.to_s('F')}"
        end
        conn[:quests].where(id: quest.fetch(:id)).update(raises) unless raises.empty?
      end

      def apply_config_merges!(quest, req, changes)
        %i[process_config model_config].each do |param|
          merge = parse_json_object(req, param)
          next unless merge

          current = quest.fetch(param) || {}
          current = JSON.parse(current) if current.is_a?(String)
          merged = current.merge(merge) # SHALLOW — the frozen merge shape
          merged.keys.select { |k| merged[k] != current[k] }.each do |key|
            changes << "#{param}.#{key} #{current[key].inspect}→#{merged[key].inspect}"
          end
          conn[:quests].where(id: quest.fetch(:id))
                       .update(param => Sequel.lit("?::jsonb", JSON.generate(merged)))
        end
      end

      def ledger_note(user, req, changes)
        note = "ui console restart door — operator #{user.username}"
        note += " — #{changes.join('; ')}" unless changes.empty?
        why = param(req, :note).to_s.strip
        note += " — why: #{why}" unless why.empty?
        note
      end
    end
  end
end
