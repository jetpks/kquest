# frozen_string_literal: true

module Watch
  module Actions
    # GET /alerts — the alerting surface (I08 §4 row 8 / I16 Part 2). The 13
    # tw_* predicates' CURRENT FIRE SETS, SELECT-only over the same views the
    # AssurancePoller reads (the poller's dedup is in-process; the views are
    # live sets). The metrics panels are REUSED from
    # Kquest::Orchestrator::Metrics' families — one rollup, no second
    # validator (the I05 §5 law applied to the UI). Every list is capped
    # (L15). The ONE write on this surface is the flash-only acknowledge;
    # the mute is I17's (ALL config-row writes concentrate there) — mute
    # state renders read-only if rows exist, no control.
    #
    # NO ENFORCEMENT: nothing here fires, mutes, or blocks on an alert — the
    # map's own law (I08 §3.4): "No consumer of this slot may act
    # automatically on an alert."
    class AlertsIndex < Kquest::Action
      include Kquest::Deps["db.gateway"]

      # The 13 tw_* predicates with their PRINCIPLED deterministic orders
      # (severity first, then the row key — never silent truncation, L15).
      FIRE_VIEWS = {
        "tw_wedge"            => [Sequel.desc(:last_event_age_s), :session_id],
        "tw_cache_wall"       => [Sequel.desc(:max_input_tokens), :session_id],
        "tw_churn"            => [Sequel.desc(:consecutive_failures), :session_id],
        "tw_context_blowout"  => [Sequel.desc(:non_sliced_read_refusals), :session_id],
        "tw_empty_storm"      => [Sequel.desc(:empty_completions), :phase_id],
        "tw_fingerprint_drift" => [Sequel.desc(:version_seq), :report_version_id],
        "tw_hub_divergence"   => [Sequel.desc(:quest_count), :canonical_text],
        "tw_missing_spend"    => [Sequel.desc(:tool_calls), :session_id],
        "tw_repetition"       => [Sequel.desc(:consecutive_identical), :session_id],
        "tw_rotation"         => [Sequel.desc(:round_no), Sequel.desc(:attempt_no), :phase_id],
        "tw_shape_storm"      => [Sequel.desc(:shape_errors), :session_id],
        "tw_size_ceiling"     => [Sequel.desc(:audit_bytes), :session_id],
        "tw_slowstall"        => [Sequel.desc(:window_bytes), :session_id]
      }.freeze

      # tw_churn / tw_repetition key on sessions without a user_id column —
      # scope them through the user's own session rows.
      SESSION_KEYED = %w[tw_churn tw_repetition].freeze

      METRICS_PANELS = %w[kquest_refusal_rate_session kquest_refusal_class_census
                          kquest_transcript_audit_bytes kquest_tripwire_fires
                          kquest_mass_curve].freeze

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        render_inertia(req, res, "Alerts/Index", props: props(user))
      end

      private

      def conn = gateway.connection

      def props(user)
        {
          fire_sets: fire_sets(user),
          metrics_panels: metrics_panels(user),
          quests: quests(user),
          stream_url: "/alerts/stream",
          mute_state: mute_state(user)
        }
      end

      def fire_sets(user)
        FIRE_VIEWS.map do |predicate, order|
          dataset = conn[property_name(predicate)]
          dataset = if SESSION_KEYED.include?(predicate)
                      dataset.where(session_id: conn[:sessions].where(user_id: user.id).select(:id))
                    else
                      dataset.where(user_id: user.id)
                    end
          {predicate: predicate, listing: capped(dataset, predicate, user)}
        end
      end

      def capped(dataset, predicate, user)
        Kquest::Ui::CappedListing.call(conn, dataset, surface: "alerts",
                                       user_id: user.id, order: FIRE_VIEWS[predicate])
      end

      def property_name(predicate)
        Sequel[predicate.to_sym]
      end

      # The reused Metrics families (one rollup — never re-derive).
      def metrics_panels(user)
        Kquest::Orchestrator::Metrics.families(conn, user_id: user.id)
                                     .select { |f| METRICS_PANELS.include?(f[:name]) }
      end

      def quests(user)
        Kquest::Ui::CappedListing.call(
          conn, conn[:quests].where(user_id: user.id),
          surface: "alerts", user_id: user.id,
          order: [Sequel.asc(:state), Sequel.desc(:created_at), :id]
        )
      end

      # Mute state renders READ-ONLY if the I17 console ever writes its rows;
      # this surface offers no mute control (ALL config-row writes are I17's).
      def mute_state(user)
        conn[:tool_config].where(Sequel.like(:key, "alerts.mute.%"))
                          .select(:key, :text_value, :provenance).to_a
      end
    end
  end
end
