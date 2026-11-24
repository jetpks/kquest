# frozen_string_literal: true

module Kquest
  module Queries
    # I01 canonical query Q2 (L3 citation-ancestry independence), transcribed
    # from design/I01-core-model/artifacts/canonical-queries.sql: evidence
    # pairs that share a SOURCE where one hangs off a claim in the other
    # claim's derivation ancestry — not independent corroborations. The
    # no-id-ordering-filter law is the frozen text's own: NO evidence-id
    # comparison across ancestry depths (it silently drops pairs whose ids
    # sort the other way); the reflexive depth-0 arm keeps exactly one row
    # per unordered pair via the id filter on that arm alone.
    class CitationAncestry
      def initialize(conn:)
        @conn = conn
      end

      def dependent_pairs(user_id:, quest_id: nil)
        @conn.fetch(<<~SQL, user_id: user_id, quest_id: quest_id).to_a
          WITH RECURSIVE ancestry (claim_id, ancestor_id, depth) AS (
            SELECT id, id, 0 FROM claims
            WHERE user_id = :user_id AND (:quest_id::uuid IS NULL OR quest_id = :quest_id)
            UNION ALL
            SELECT a.claim_id, d.parent_claim_id, a.depth + 1
            FROM ancestry a
            JOIN claim_derivations d ON d.claim_id = a.ancestor_id AND d.user_id = :user_id
          )
          SELECT DISTINCT eb.claim_id AS ancestor_claim_id, ea.claim_id AS claim_id,
                 ea.evidence_id AS evidence_b, eb.evidence_id AS evidence_a,
                 evb.source_id AS shared_source_id,
                 an.depth AS ancestor_depth
          FROM evidence_edges ea
          JOIN evidence_edges eb
            ON eb.quest_id = ea.quest_id
          JOIN evidence eva ON eva.id = ea.evidence_id AND eva.quest_id = ea.quest_id
          JOIN evidence evb ON evb.id = eb.evidence_id AND evb.quest_id = eb.quest_id
                           AND evb.source_id = eva.source_id
          JOIN ancestry an ON an.claim_id = ea.claim_id AND an.ancestor_id = eb.claim_id
                           AND (an.depth > 0 OR eb.evidence_id < ea.evidence_id)
          WHERE ea.user_id = :user_id
          ORDER BY claim_id, ancestor_claim_id, evidence_a
        SQL
      end
    end
  end
end
