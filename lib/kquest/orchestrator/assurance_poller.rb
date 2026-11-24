# frozen_string_literal: true

require "json"
require "set"
require_relative "../tools"
require_relative "event_publisher"

module Kquest
  module Orchestrator
    # The `assurance_alert` poller (I07 §4, DR-07/DR-10; I08 §3.4): evaluates
    # the 13 `tw_*` catalog views BY NAME on a cadence (`tool_config`
    # `assurance.poll_interval_s` = 30 s default), hosted by the LAUNCHER —
    # one global pass per cadence over live quests, because
    # `tw_hub_divergence` and `tw_fingerprint_drift` are CROSS-QUEST
    # predicates a per-quest host would double-fire.
    #
    # Each fire → one `assurance_alert` XADD onto the owning quest's stream
    # (the predicate id + its key fields per the I07 §4.1 payload column:
    # `tw_wedge` carries `last_tool`; `tw_size_ceiling` carries band+bytes;
    # `tw_fingerprint_drift` carries `pin_kind`), and the cross-quest fires
    # also land on the owning user's global stream.
    #
    # SIGNAL ONLY: the poller is SELECT-only over the views — it NEVER
    # mutates `quests`/`phases`/`sessions`, never transitions, never kills
    # (the eval-not-binding law, standing lesson #3). Each (predicate, row)
    # fires once per poller lifetime (an in-process dedup; a restarted
    # poller re-fires — the alert surface dedupes by id).
    class AssurancePoller
      # The 13 catalog views BY NAME (the I07 §4.1 table — checker-parity
      # both directions).
      PREDICATES = %w[
        tw_wedge tw_slowstall tw_size_ceiling tw_churn tw_rotation
        tw_empty_storm tw_repetition tw_missing_spend tw_cache_wall
        tw_shape_storm tw_context_blowout tw_hub_divergence tw_fingerprint_drift
      ].freeze

      # The cross-quest predicates (they fire once globally, onto the owning
      # user's stream as well as the owning quest's).
      CROSS_QUEST = %w[tw_hub_divergence tw_fingerprint_drift].freeze

      DEFAULT_INTERVAL_S = 30

      def initialize(conn:, publisher:)
        @conn = conn
        @publisher = publisher
        @fired = Set.new
      end

      # The cadence from the config row (`assurance.poll_interval_s`).
      def interval_s
        value = Kquest::Tools.config_value(Kquest::Tools.config(@conn),
                                           "assurance.poll_interval_s")
        value ? Integer(value) : DEFAULT_INTERVAL_S
      end

      # One global pass. Returns the number of fires published.
      def pass
        count = 0
        PREDICATES.each do |predicate|
          @conn[predicate.to_sym].each do |row|
            key = fire_key(predicate, row)
            next unless @fired.add?(key)

            publish_fire(predicate, row)
            count += 1
          end
        end
        count
      end

      private

      # The row's natural key (the fire identity — a stuck wedge session
      # fires once; a NEW wedge row fires again).
      def fire_key(predicate, row)
        identity = case predicate
                   when "tw_wedge", "tw_slowstall", "tw_missing_spend", "tw_cache_wall",
                        "tw_shape_storm", "tw_context_blowout"
                     row.fetch(:session_id)
                   when "tw_size_ceiling", "tw_empty_storm", "tw_rotation"
                     row.fetch(:phase_id) || row.fetch(:session_id)
                   when "tw_churn", "tw_repetition"
                     "#{row.fetch(:session_id)}:#{row.fetch(:last_seq) || row.fetch(:first_seq)}"
                   when "tw_hub_divergence"
                     "#{row.fetch(:user_id)}:#{row.fetch(:canonical_text)}"
                   when "tw_fingerprint_drift"
                     row.fetch(:report_version_id) ||
                       "#{row.fetch(:quest_id)}:#{row.fetch(:pinned_fingerprint)}"
                   end
        [predicate, identity.to_s]
      end

      def publish_fire(predicate, row)
        data = {"predicate" => predicate}
        row.each do |column, value|
          data[column.to_s] =
            case value
            when Time then value.utc.iso8601
            when BigDecimal then value.to_s("F")
            when nil then nil
            else value.to_s
            end
        end
        quest_id = resolve_quest(predicate, row)
        @publisher.publish_quest(quest_id, "assurance_alert", data) if quest_id
        # The cross-quest fires land on the user's global stream too.
        if CROSS_QUEST.include?(predicate)
          @publisher.publish_user(row.fetch(:user_id), "assurance_alert", data)
        end
        data
      end

      # The owning quest: the rows that carry quest_id directly; the
      # session-keyed rows resolve through the session row (SELECT-only).
      def resolve_quest(predicate, row)
        return row[:quest_id] if row.key?(:quest_id) && row[:quest_id]

        session_id = row[:session_id]
        session_id && @conn[:sessions].where(id: session_id).get(:quest_id)
      end
    end
  end
end
