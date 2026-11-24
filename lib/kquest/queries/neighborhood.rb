# frozen_string_literal: true

module Kquest
  module Queries
    # I01 canonical query Q3 (L15 neighborhood read), transcribed from
    # design/I01-core-model/artifacts/canonical-queries.sql: a bounded-radius,
    # cycle-safe walk from one node over the undirected view of the graph —
    # derivations both directions, evidence edges both directions, frontier
    # entries, evidence → source. The neighbors tool's `types`/`direction`
    # parameters filter the lateral edge fan; the 50-alias cap (T-CAP) bounds
    # the listing.
    class Neighborhood
      def initialize(conn:)
        @conn = conn
      end

      # Returns rows {node_kind, node_id, depth, preview} ordered by
      # (depth, node_kind, node_id), cycle-safe via the UNION dedup + depth
      # cap. direction ∈ both|in|out; types ⊆ derives_from|supports|contradicts.
      def hood(center_id, user_id:, quest_id:, radius: 2, direction: "both", types: nil)
        in_edges = direction != "out"
        out_edges = direction != "in"
        types ||= %w[derives_from supports contradicts]
        # validated against the schema's own enum before any interpolation
        bad = types - %w[derives_from supports contradicts]
        raise ArgumentError, "unknown edge type: #{bad.inspect}" if bad.any?
        evidence_types = types & %w[supports contradicts]
        etypes_sql = evidence_types.map { |t| "'#{t}'" }.join(", ")
        derivations = types.include?("derives_from")
        params = {center_id: center_id, user_id: user_id, quest_id: quest_id,
                  radius: radius, in_edges: in_edges, out_edges: out_edges,
                  derivations: derivations, evidence_types: nil}
        @conn.fetch(<<~SQL, params).to_a
          WITH RECURSIVE hood (node_kind, node_id, depth) AS (
            SELECT 'claim', c.id, 0 FROM claims c
            WHERE c.id = :center_id AND c.user_id = :user_id AND c.quest_id = :quest_id
            UNION
            SELECT h.node_kind, e.next_id, h.depth + 1
            FROM hood h
            JOIN LATERAL (
              SELECT 'claim' AS next_kind, d.parent_claim_id AS next_id
              FROM claim_derivations d
              WHERE :derivations AND :out_edges AND h.node_kind = 'claim' AND d.claim_id = h.node_id
              UNION ALL
              SELECT 'claim', d.claim_id
              FROM claim_derivations d
              WHERE :derivations AND :in_edges AND h.node_kind = 'claim' AND d.parent_claim_id = h.node_id
              UNION ALL
              SELECT 'evidence', ee.evidence_id
              FROM evidence_edges ee
              WHERE :in_edges AND h.node_kind = 'claim' AND ee.claim_id = h.node_id
                AND ee.relation IN (#{etypes_sql})
              UNION ALL
              SELECT 'frontier', f.id
              FROM frontier_entries f
              WHERE h.node_kind = 'claim' AND f.claim_id = h.node_id
              UNION ALL
              SELECT 'source', ev.source_id
              FROM evidence ev
              WHERE h.node_kind = 'evidence' AND ev.id = h.node_id
              UNION ALL
              SELECT 'claim', ee2.claim_id
              FROM evidence_edges ee2
              WHERE :out_edges AND h.node_kind = 'evidence' AND ee2.evidence_id = h.node_id
                AND ee2.relation IN (#{etypes_sql})
            ) e ON true
            WHERE h.depth < :radius
          )
          SELECT DISTINCT ON (node_kind, node_id) node_kind, node_id, depth
          FROM hood
          ORDER BY node_kind, node_id, depth
        SQL
      end
    end
  end
end
