# frozen_string_literal: true

module Kquest
  module Orchestrator
    # The `/metrics` exposition (I07 §5, shape — the no-gem ruling: no
    # fast-prometheus gem exists, so the endpoint lands the Prometheus
    # text-exposition SHAPE directly, app-side: `# HELP`/`# TYPE` headers +
    # labelled sample lines). Every family is computed as a VIEW over the
    # durable ledgers — NO second bookkeeping, no new mutation surface (I07
    # §5 law: double-entry stays single-entry at the metric layer). The
    # renderer is a plain module: given the live DB it produces the exact
    # exposition text (keyless-unit-tested against fixture ledger rows).
    #
    # Families (I07 §5's table, label axes where it says so):
    #   refusal_rate_session, refusal_class_census, empty_completion_rate,
    #   closure_economics_cost_per_class, cost_per_claim, cost_per_evidence,
    #   mass_curve, metabolism (the R-018 ratios), spend (the token/cost
    #   sums by session→phase→quest→user), transcript_audit_bytes,
    #   tripwire_fires — plus the blind-spot day-one four (I07 DR-05 ruling
    #   A): unmined_citable, fetched_never_cited, uncited_claims,
    #   aging_open_needs. The tool-layer cap-telemetry family does NOT land
    #   (I07 DR-05's own deferral — it needs tool-layer cap telemetry).
    module Metrics
      module_function

      # The exposition for one requesting user's tenancy (the authenticated
      # posture — the recorded ruling: labels carry quest/user/session ids,
      # no unauthenticated internal-data surface day one).
      def render(conn, user_id:)
        families(conn, user_id: user_id).map { |f| render_family(f) }.join
      end

      # One family: {name:, help:, type:, samples: [{labels:, value:}]}.
      def render_family(family)
        out = +"# HELP #{family[:name]} #{family[:help]}\n"
        out << "# TYPE #{family[:name]} #{family[:type]}\n"
        family[:samples].each do |sample|
          labels = sample[:labels].map { |k, v| "#{k}=#{format_label(v)}" }.join(",")
          out << "#{family[:name]}{#{labels}} #{format_value(sample[:value])}\n"
        end
        out
      end

      def format_label(v) = "\"#{v}\""

      def format_value(v)
        case v
        when BigDecimal then v.to_s("F")
        when Float then v.to_s
        when Integer then v.to_s
        else v.to_s
        end
      end

      # ── the families over the durable ledgers ───────────────────────────

      def families(conn, user_id:)
        quests = conn[:quests].where(user_id: user_id).select(:id).map { |r| r.fetch(:id) }
        return [] if quests.empty?

        [
          refusal_rate_session(conn, quests),
          refusal_class_census(conn, quests),
          empty_completion_rate(conn, quests),
          closure_economics(conn, quests),
          *cost_per(conn, quests),
          mass_curve(conn, quests),
          metabolism(conn, quests),
          spend(conn, quests),
          transcript_audit_bytes(conn, quests),
          tripwire_fires(conn, quests),
          *blind_spots(conn, quests)
        ]
      end

      def refusal_rate_session(conn, quests)
        rows = conn[:tool_calls].where(quest_id: quests)
                                .group(:session_id, :quest_id, :user_id)
                                .select(:session_id, :quest_id, :user_id,
                                        Sequel.lit("count(*) FILTER (WHERE NOT ok)::float / " \
                                                   "greatest(count(*), 1)::float AS rate"))
        {name: "kquest_refusal_rate_session",
         help: "Refusal rate per session (tool_calls ok=false / total) — the quest-2 taxonomy ratio",
         type: "gauge",
         samples: rows.map { |r| {labels: {"quest_id" => r[:quest_id].to_s,
                                           "session_id" => r[:session_id].to_s,
                                           "user_id" => r[:user_id].to_s},
                                  value: r[:rate] || 0.0}} }
      end

      def refusal_class_census(conn, quests)
        rows = conn[:tool_calls].where(quest_id: quests).where(ok: false)
                                .group(:error_class, :session_id, :quest_id)
                                .select(:error_class, :session_id, :quest_id,
                                        Sequel.lit("count(*) AS calls"))
        {name: "kquest_refusal_class_census",
         help: "Refusal calls per error_class per session — the quest-2 taxonomy classes",
         type: "counter",
         samples: rows.map { |r| {labels: {"quest_id" => r[:quest_id].to_s,
                                           "session_id" => r[:session_id].to_s,
                                           "error_class" => r[:error_class].to_s},
                                  value: r[:calls]}} }
      end

      def empty_completion_rate(conn, quests)
        rows = conn[:usage_events].where(quest_id: quests, kind: "llm")
                                  .group(:phase_id, :quest_id)
                                  .select(:phase_id, :quest_id,
                                          Sequel.lit("count(*) FILTER (WHERE input_tokens > 0 " \
                                                     "AND output_tokens = 0)::float / " \
                                                     "greatest(count(*), 1)::float AS rate"))
        {name: "kquest_empty_completion_rate",
         help: "Empty-completion rate per phase (input billed, output zero — FM-01)",
         type: "gauge",
         samples: rows.map { |r| {labels: {"quest_id" => r[:quest_id].to_s,
                                           "phase_id" => r[:phase_id].to_s},
                                  value: r[:rate] || 0.0}} }
      end

      # Closing-phase attribution: a frontier entry belongs to the phase
      # whose session window contains its closed_at (I07 §5's formula).
      def closure_economics(conn, quests)
        rows = conn.fetch(<<~SQL, "{#{quests.join(',')}}").to_a
          SELECT p.id AS phase_id, p.quest_id, f.closure_type,
                 coalesce(sum(ue.cost_usd), 0) AS cost, count(f.id) AS closures
          FROM frontier_entries f
          JOIN phases p ON p.quest_id = f.quest_id
            AND f.closed_at BETWEEN p.started_at AND coalesce(p.ended_at, now())
          LEFT JOIN usage_events ue ON ue.phase_id = p.id
          WHERE f.quest_id = ANY(string_to_array(?, ',')::uuid[])
            AND f.state = 'closed' AND f.closure_type IS NOT NULL
          GROUP BY p.id, p.quest_id, f.closure_type
        SQL
        {name: "kquest_closure_economics_cost_per_class",
         help: "Spend USD per frontier closure by closure_type (fetch/internal/refusal)",
         type: "gauge",
         samples: rows.map { |r| {labels: {"quest_id" => r[:quest_id].to_s,
                                           "phase_id" => r[:phase_id].to_s,
                                           "closure_type" => r[:closure_type]},
                                  value: r[:closures].zero? ? BigDecimal("0")
                                                            : BigDecimal(r[:cost].to_s) / r[:closures]}} }
      end

      def cost_per(conn, quests)
        spend_rows = conn[:usage_events].where(quest_id: quests).group(:quest_id)
                                        .select(:quest_id,
                                                Sequel.lit("coalesce(sum(cost_usd), 0) AS cost"))
        cost_by_quest = spend_rows.to_h { |r| [r[:quest_id], BigDecimal(r[:cost].to_s)] }
        claim_counts = conn[:claims].where(quest_id: quests).group(:quest_id)
                                    .select(:quest_id, Sequel.lit("count(*) AS n"))
                                    .to_h { |r| [r[:quest_id], r[:n]] }
        evidence_counts = conn[:evidence].where(quest_id: quests).group(:quest_id)
                                         .select(:quest_id, Sequel.lit("count(*) AS n"))
                                         .to_h { |r| [r[:quest_id], r[:n]] }
        [
          {name: "kquest_cost_per_claim",
           help: "Spend USD per claim node",
           type: "gauge",
           samples: claim_counts.keys.map do |quest_id|
             n = claim_counts.fetch(quest_id)
             {labels: {"quest_id" => quest_id.to_s},
              value: n.zero? ? BigDecimal("0") : cost_by_quest.fetch(quest_id, BigDecimal("0")) / n}
           end },
          {name: "kquest_cost_per_evidence",
           help: "Spend USD per evidence node",
           type: "gauge",
           samples: evidence_counts.keys.map do |quest_id|
             n = evidence_counts.fetch(quest_id)
             {labels: {"quest_id" => quest_id.to_s},
              value: n.zero? ? BigDecimal("0") : cost_by_quest.fetch(quest_id, BigDecimal("0")) / n}
           end }
        ]
      end

      def mass_curve(conn, quests)
        rows = conn[:phases].where(quest_id: quests).exclude(frontier_mass: nil)
                            .order(:created_at)
                            .select(:quest_id, :id, :kind, :round_no, :frontier_mass)
        {name: "kquest_mass_curve",
         help: "Frontier mass at each phase boundary snapshot (the I01 mass law)",
         type: "gauge",
         samples: rows.map { |r| {labels: {"quest_id" => r[:quest_id].to_s,
                                           "phase_id" => r[:id].to_s,
                                           "phase_kind" => r[:kind],
                                           "round_no" => r[:round_no].to_s},
                                  value: r[:frontier_mass]}} }
      end

      def metabolism(conn, quests)
        samples = quests.flat_map do |quest_id|
          sources = conn[:quest_sources].where(quest_id: quest_id).count
          next [] if sources.zero?

          evidence = conn[:evidence].where(quest_id: quest_id).count
          claims = conn[:claims].where(quest_id: quest_id).count
          fetches = conn[:frontier_entries].where(quest_id: quest_id, closure_type: "fetch").count
          internals = conn[:frontier_entries].where(quest_id: quest_id,
                                                    closure_type: "internal").count
          web_per_fetch = fetches.zero? ? 0.0 : web_calls(conn, quest_id).to_f / fetches
          web_per_internal = internals.zero? ? 0.0 : web_calls(conn, quest_id).to_f / internals
          [["evidence_per_source", evidence.to_f / sources],
           ["claims_per_source", claims.to_f / sources],
           ["web_per_fetch", web_per_fetch],
           ["web_per_internal", web_per_internal]].map do |ratio, value|
            {labels: {"quest_id" => quest_id.to_s, "ratio" => ratio}, value: value}
          end
        end
        {name: "kquest_metabolism",
         help: "The R-018 ratios: evidence/claims per source, web calls per closure class",
         type: "gauge",
         samples: samples}
      end

      def web_calls(conn, quest_id)
        conn[:tool_calls].where(quest_id: quest_id, ok: true)
                         .where(Sequel[:tool] => %w[web_search web_fetch]).count
      end

      def spend(conn, quests)
        rows = conn[:usage_events].where(quest_id: quests)
                                  .group(:session_id, :phase_id, :quest_id, :user_id)
                                  .select(:session_id, :phase_id, :quest_id, :user_id,
                                          Sequel.lit("coalesce(sum(cost_usd), 0) AS cost"),
                                          Sequel.lit("coalesce(sum(input_tokens), 0) AS input_tokens"),
                                          Sequel.lit("coalesce(sum(output_tokens), 0) AS output_tokens"))
        {name: "kquest_spend",
         help: "Token/cost sums by session→phase→quest→user (the D10 ledger)",
         type: "counter",
         samples: rows.flat_map { |r|
           [{"kind" => "cost_usd", "value" => BigDecimal(r[:cost].to_s)},
            {"kind" => "input_tokens", "value" => r[:input_tokens] || 0},
            {"kind" => "output_tokens", "value" => r[:output_tokens] || 0}].map do |entry|
             {labels: {"quest_id" => r[:quest_id].to_s, "phase_id" => r[:phase_id].to_s,
                       "session_id" => r[:session_id].to_s, "user_id" => r[:user_id].to_s,
                       "kind" => entry["kind"]},
              value: entry["value"]}
           end
         } }
      end

      def transcript_audit_bytes(conn, quests)
        rows = conn[:tool_calls].where(quest_id: quests)
                                .group(:session_id, :quest_id, :user_id)
                                .select(:session_id, :quest_id, :user_id,
                                        Sequel.lit("coalesce(sum(octet_length(args::text) + " \
                                                   "octet_length(result::text)), 0) AS bytes"))
        {name: "kquest_transcript_audit_bytes",
         help: "Verbatim audit payload bytes per session (the durable LOWER bound — DR-07)",
         type: "gauge",
         samples: rows.map { |r| {labels: {"quest_id" => r[:quest_id].to_s,
                                           "session_id" => r[:session_id].to_s,
                                           "user_id" => r[:user_id].to_s},
                                  value: r[:bytes]}} }
      end

      def tripwire_fires(conn, quests)
        predicates = %w[tw_wedge tw_slowstall tw_size_ceiling tw_churn tw_rotation
                        tw_empty_storm tw_repetition tw_missing_spend tw_cache_wall
                        tw_shape_storm tw_context_blowout tw_hub_divergence
                        tw_fingerprint_drift]
        samples = predicates.filter_map do |predicate|
          count = conn[predicate.to_sym].where(Sequel.lit("true")).count
          {labels: {"predicate" => predicate}, value: count} if count.positive?
        end
        {name: "kquest_tripwire_fires",
         help: "Current fire count per I07 tripwire predicate",
         type: "gauge",
         samples: samples}
      end

      # The blind-spot day-one four (I07 DR-05 ruling A: the SQL-expressible
      # rows; the cap-telemetry family needs tool telemetry — deferred).
      def blind_spots(conn, quests)
        unmined = conn[:v_unmined_sources].where(quest_id: quests).group(:quest_id)
                                          .select(:quest_id, Sequel.lit("count(*) AS n"))
        users = conn[:quests].where(id: quests).select_map(:user_id).uniq
        fetched_never_cited = conn[:sources]
                              .where(user_id: users, role: "citable")
                              .exclude(id: conn[:evidence].select(:source_id))
                              .group(:user_id)
                              .select(:user_id, Sequel.lit("count(*) AS n"))
        uncited = conn[:v_claim_closure].where(quest_id: quests)
                                        .where(Sequel.lit("evidence_count = 0"))
                                        .group(:quest_id)
                                        .select(:quest_id, Sequel.lit("count(*) AS n"))
        aging = conn[:frontier_entries].where(quest_id: quests, state: "open")
                                       .where(Sequel.lit("now() - opened_at > interval '7 days'"))
                                       .group(:quest_id)
                                       .select(:quest_id, Sequel.lit("count(*) AS n"))
        [
          {name: "kquest_unmined_citable", help: "Staged, citable, never anchored (blind spot)",
           type: "gauge",
           samples: unmined.map { |r| {labels: {"quest_id" => r[:quest_id].to_s}, value: r[:n]}} },
          {name: "kquest_fetched_never_cited",
           help: "Citable sources with zero evidence across the user's quests (blind spot)",
           type: "gauge",
           samples: fetched_never_cited.map { |r| {labels: {"user_id" => r[:user_id].to_s},
                                                   value: r[:n]}} },
          {name: "kquest_uncited_claims",
           help: "Claims referencing zero evidence, closure satisfied by terminal/frontier arm",
           type: "gauge",
           samples: uncited.map { |r| {labels: {"quest_id" => r[:quest_id].to_s}, value: r[:n]}} },
          {name: "kquest_aging_open_needs",
           help: "Open frontier needs older than the 7-day band (blind spot)",
           type: "gauge",
           samples: aging.map { |r| {labels: {"quest_id" => r[:quest_id].to_s}, value: r[:n]}} }
        ]
      end
    end
  end
end
