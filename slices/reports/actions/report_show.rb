# frozen_string_literal: true

module Reports
  module Actions
    # GET /quests/:quest_id/report — the REPORT VIEW (I08 §4 row 5 / I16
    # Part 7): the version chain (capped), the standing body's citation map
    # (ordinals → URNs through the landed ReportBinding machinery, read-only),
    # the STALENESS BANNER (pinned ≠ live fingerprint, per tw_fingerprint_drift's
    # shape — DETECTED, not prevented), and the arc's stop markers in synthesis
    # provenance (CUT AT MASS / DRAINED / STOPPED-LOUD — distinguishable
    # forever, I06 §5 item 4). Draft/bind/flip are I17's session-bearing
    # writes. ONE action of our own here: the body-blob download (ReportBody).
    class ReportShow < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        return halt_not_found(res) unless Kquest::Ui::Visibility.visible_quest?(
          conn, user_id: user.id, quest_id: quest_id
        )

        render_inertia(req, res, "Reports/Show", props: props(user, quest_id))
      end

      private

      def conn = gateway.connection

      def props(user, quest_id)
        versions = Kquest::Ui::CappedListing.call(
          conn, conn[:report_versions].where(quest_id: quest_id),
          surface: "reports", user_id: user.id, quest_id: quest_id,
          order: [Sequel.desc(:version_seq), :id]
        )
        standing = versions[:rows].find { |r| r.fetch(:standing) } ||
                   versions[:rows].first

        {
          versions: versions,
          standing: standing && standing_props(standing),
          citations: citations(user, quest_id, standing),
          binding_index: binding(user, quest_id, standing),
          staleness: staleness(quest_id, standing),
          stop_markers: stop_markers(quest_id)
        }
      end

      def standing_props(version)
        {
          id: version.fetch(:id), version_seq: version.fetch(:version_seq),
          standing: version.fetch(:standing), bound_at: version.fetch(:bound_at),
          binding_pass: version.fetch(:binding_pass), model: version.fetch(:model),
          quest_fingerprint: version.fetch(:quest_fingerprint),
          body_url: body_url(version)
        }
      end

      def body_url(version)
        "/quests/#{version.fetch(:quest_id)}/report/versions/#{version.fetch(:version_seq)}/body"
      end

      # The ordinals → URN citation map for the standing version (read-only
      # over report_citations).
      def citations(user, quest_id, standing)
        return [] unless standing

        conn[:report_citations].where(report_version_id: standing.fetch(:id))
                               .order(Sequel.asc(:ordinal), :id).to_a
      end

      # The binding-pass manifest through the LANDED ReportBinding machinery
      # (never re-derived): the citation index (the ordinal space) + the import
      # manifest of the standing version.
      def binding(user, quest_id, standing)
        binding_query = Kquest::Queries::ReportBinding.new(conn: conn)
        {
          citation_index: binding_query.citation_index(user_id: user.id, quest_id: quest_id),
          import_manifest: standing ? binding_query.import_manifest(standing) : []
        }
      end

      # The STALENESS banner (tw_fingerprint_drift's shape, DETECTED-not-
      # prevented): the standing version's PINNED fingerprint vs the quest's
      # live fingerprint (v_quest_graph_fingerprint).
      def staleness(quest_id, standing)
        live = conn[:v_quest_graph_fingerprint].where(quest_id: quest_id)
                                               .get(:graph_fingerprint)
        pinned = standing && standing.fetch(:quest_fingerprint)
        {stale: !pinned.nil? && pinned != live, pinned_fingerprint: pinned,
         live_fingerprint: live}
      end

      # The arc's stop markers in synthesis provenance (I06 §5 item 4): the
      # phases' result "stop" keys — the SAME durable shape
      # Kquest::Orchestrator::PhaseContract#carried_stop_markers reads (the
      # jsonb→ruby typing varies by extension load order across connections,
      # so the text form is the honest constant, same as the contract's own
      # read).
      def stop_markers(quest_id)
        conn[:phases].where(quest_id: quest_id).exclude(result: nil).order(:created_at)
                     .select(Sequel.lit("result::text AS result_text")).to_a
                     .filter_map do |row|
          stop = parse_marker(row.fetch(:result_text))
          next unless stop

          {rule_id: stop["rule_id"], phase_no: stop["phase_no"],
           phase_kind: stop["phase_kind"], reason: stop["reason"], route: stop["route"]}
        end
      end

      def parse_marker(text)
        JSON.parse(text.to_s)["stop"]
      rescue JSON::ParserError, TypeError
        nil
      end
    end
  end
end
