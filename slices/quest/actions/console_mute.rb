# frozen_string_literal: true

module Quest
  module Actions
    # POST /quests/:quest_id/console/mute — the alerting mute (I17 Part 6):
    # the ONE config-ROW write in the iteration (ALL config-row writes
    # concentrate here — one writer discipline). ONE `tool_config` row per
    # (quest, predicate): key `alerts.mute.<quest_id>.<predicate>`,
    # `text_value` = the reason (the why), `provenance` = operator who/why —
    # the I16-landed mute_state reader's own carrier shape; upsert-shaped
    # (re-muting replaces the row). `remove` deletes the row (the filter's
    # removal — the signal's ledger rows were never touched). This is a
    # DISPLAY FILTER ONLY: it never publishes, never mutes a tripwire,
    # never blocks a ledger row. `tw_hub_divergence` is NOT muteable — it
    # routes to adjudication (I08 §5.1 row 9). No lifecycle row (no
    # transition occurred).
    class ConsoleMute < Kquest::Action
      include Kquest::Deps["db.gateway"]

      # The 13 tw_* predicates (the landed AlertsIndex::FIRE_VIEWS census —
      # the same vocabulary; the hub-divergence row is adjudication's).
      PREDICATES = %w[tw_wedge tw_cache_wall tw_churn tw_context_blowout tw_empty_storm
                      tw_fingerprint_drift tw_hub_divergence tw_missing_spend tw_repetition
                      tw_rotation tw_shape_storm tw_size_ceiling tw_slowstall].freeze
      NOT_MUTEABLE = "tw_hub_divergence"

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        return halt_not_found(res) unless Kquest::Ui::OperatorWrite.owner_quest!(
          conn, user_id: user.id, quest_id: quest_id
        )

        refusal = validate(req, user)
        if refusal
          halt_unprocessable(res, [refusal])
        end

        key = "alerts.mute.#{quest_id}.#{req.params[:predicate]}"
        if remove?(req)
          conn.transaction do
            row = conn[:tool_config].where(key: key).first
            raise Refusal, "no mute row for #{req.params[:predicate]} on this quest — " \
                           "nothing to remove (the display filter is the row)" unless row

            conn[:tool_config].where(key: key).delete
          end
          redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/console",
                                   notice: "Unmuted #{req.params[:predicate]} — the signal's " \
                                           "ledger rows were never touched.")
        else
          reason = req.params[:reason].to_s.strip
          conn.transaction do
            conn[:tool_config].where(key: key).delete
            conn[:tool_config].insert(
              key: key, num_value: nil, text_value: reason,
              provenance: "operator #{user.username} #{Time.now.utc.iso8601} — #{reason}"
            )
          end
          redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/console",
                                   notice: "Muted #{req.params[:predicate]} for this quest — " \
                                           "a display filter, recorded with who/why.")
        end
      rescue Refusal => e
        halt_unprocessable(res, [e.message])
      end

      private

      def conn = gateway.connection

      class Refusal < StandardError; end

      def remove?(req)
        %w[true 1 on].include?(req.params[:remove].to_s.downcase)
      end

      # The teaching checks: a known predicate, the hub signal routed to
      # adjudication instead, a REQUIRED non-empty reason (the why) — and the
      # row-exists check for removal rides its transaction.
      def validate(req, user)
        predicate = req.params[:predicate].to_s
        return "unknown predicate #{predicate.inspect} — the muteable set is the 13 tw_* signals" \
          unless PREDICATES.include?(predicate)
        return "#{NOT_MUTEABLE} is NOT muteable — it routes to adjudication in the source quest " \
               "(the graph browser's courtroom docket)" if predicate == NOT_MUTEABLE
        return "a reason is REQUIRED — the mute row records who/why, never a silent filter" \
          if !remove?(req) && req.params[:reason].to_s.strip.empty?

        nil
      end
    end
  end
end
