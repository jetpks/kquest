-- ============================================================================
-- kquest I01 core-model — the four canonical queries (canonical-queries.sql)
-- ----------------------------------------------------------------------------
-- R-016 / D2: named query objects drafted as recursive CTEs over the core
-- schema, each returning >= 1 row against the seed fixtures. They are the
-- storage-seam query contracts later iterations bind to:
--   Q1 derivation paths to typed terminals        (L2 — done = paths reach
--      terminals; the dangling-leaf half is the violation table Q1V)
--   Q2 citation-ancestry independence             (L3 — evidence pairs that
--      share a source within a claim's derivation ancestry)
--   Q3 neighborhood read                          (L15 — bounded-radius,
--      cycle-safe walk from a claim)
--   Q4 dedup candidates via quest lineage         (L5 dedup guard — exact
--      canonical-text matches against ancestor quests; the embedding-based
--      near-dup extension is ENTRY 3, R-036, and will join this query's
--      shape, not replace it)
-- Assertions at the end make emptiness a hard failure: psql -f exits nonzero
-- unless every query returned rows (and the seed graph is L2-clean).
-- Authored plpgsql-free (assert = temp table + CHECK constraint).
-- ============================================================================

-- fixture anchors (ids are fixed in seed.sql)
\set QA 'b0000000-0000-4000-8000-000000000001'
\set QB 'b0000000-0000-4000-8000-000000000002'
\set K4 'f0000000-0000-4000-8000-000000000004'

\echo '=== Q1: derivation paths to typed terminals (L2) ==='
-- Walk derives_from edges from every deriving claim to its transitive
-- parents; keep the rows whose terminal node IS typed. This is the positive
-- half of the L2 check; Q1V below is the dangling-leaf violation half.
CREATE TEMP TABLE q1_derivation_paths AS
WITH RECURSIVE walk (quest_id, origin_claim_id, origin_seq, node_id, depth, terminal_type) AS (
  SELECT d.quest_id, d.claim_id, c.quest_seq, d.parent_claim_id, 1, p.terminal_type
  FROM claim_derivations d
  JOIN claims c ON c.id = d.claim_id
  JOIN claims p ON p.id = d.parent_claim_id
  UNION ALL
  SELECT w.quest_id, w.origin_claim_id, w.origin_seq, d.parent_claim_id, w.depth + 1, p.terminal_type
  FROM walk w
  JOIN claim_derivations d ON d.claim_id = w.node_id AND d.quest_id = w.quest_id
  JOIN claims p ON p.id = d.parent_claim_id
)
SELECT quest_id, origin_seq, origin_claim_id, depth, node_id AS terminal_claim_id, terminal_type
FROM walk
WHERE terminal_type IS NOT NULL;

SELECT * FROM q1_derivation_paths ORDER BY origin_seq, depth;

\echo '=== Q1V: L2 violations — derivation paths dangling mid-air ==='
-- A walk node that is not terminal, has no further derivations, and carries
-- no open frontier entry satisfies nothing: the closure contract is broken.
-- (Phase gates fail quests on this table being non-empty; the seed graph is
-- clean by construction, asserted below.)
CREATE TEMP TABLE q1_l2_violations AS
WITH RECURSIVE walk (quest_id, origin_claim_id, node_id, depth, terminal_type) AS (
  SELECT d.quest_id, d.claim_id, d.parent_claim_id, 1, p.terminal_type
  FROM claim_derivations d
  JOIN claims p ON p.id = d.parent_claim_id
  UNION ALL
  SELECT w.quest_id, w.origin_claim_id, d.parent_claim_id, w.depth + 1, p.terminal_type
  FROM walk w
  JOIN claim_derivations d ON d.claim_id = w.node_id AND d.quest_id = w.quest_id
  JOIN claims p ON p.id = d.parent_claim_id
)
SELECT DISTINCT w.quest_id, w.origin_claim_id, w.node_id AS dangling_claim_id, w.depth
FROM walk w
WHERE w.terminal_type IS NULL
  AND NOT EXISTS (SELECT 1 FROM claim_derivations d WHERE d.claim_id = w.node_id)
  AND NOT EXISTS (SELECT 1 FROM frontier_entries f
                  WHERE f.claim_id = w.node_id AND f.state = 'open');

SELECT * FROM q1_l2_violations;
SELECT count(*) AS l2_violation_count FROM q1_l2_violations;

\echo '=== Q2: citation-ancestry independence (L3) ==='
-- Ancestry closure per claim (reflexive + derives_from parents), then:
-- evidence pairs (a, b) that cite the SAME source where b hangs off a claim
-- in a's claim-ancestry — i.e. not independent corroborations. The fixture
-- pair (e1 on k2, e3 on k4) shares source s2 with k2 an ancestor of k4.
CREATE TEMP TABLE q2_dependent_evidence AS
WITH RECURSIVE ancestry (quest_id, claim_id, ancestor_id, depth) AS (
  SELECT quest_id, id, id, 0 FROM claims
  UNION ALL
  SELECT a.quest_id, a.claim_id, d.parent_claim_id, a.depth + 1
  FROM ancestry a
  JOIN claim_derivations d ON d.claim_id = a.ancestor_id AND d.quest_id = a.quest_id
)
SELECT DISTINCT ea.quest_id,
       eb.claim_id AS ancestor_claim_id, ea.claim_id AS claim_id,
       ea.evidence_id AS evidence_b, eb.evidence_id AS evidence_a,
       evb.source_id AS shared_source_id,
       an.depth AS ancestor_depth
FROM evidence_edges ea
JOIN evidence_edges eb
  ON eb.quest_id = ea.quest_id AND eb.evidence_id < ea.evidence_id
JOIN evidence eva ON eva.id = ea.evidence_id AND eva.quest_id = ea.quest_id
JOIN evidence evb ON evb.id = eb.evidence_id AND evb.quest_id = eb.quest_id
                 AND evb.source_id = eva.source_id
JOIN ancestry an ON an.claim_id = ea.claim_id AND an.ancestor_id = eb.claim_id;

SELECT * FROM q2_dependent_evidence
ORDER BY claim_id, ancestor_claim_id, evidence_a;

\echo '=== Q3: neighborhood read (L15, radius 2, cycle-safe) ==='
-- Bounded-radius walk from a center claim over the undirected view of the
-- graph (claims <-> derivations, claims <-> evidence edges, claims <->
-- frontier, evidence -> sources). UNION-deduplicated rows plus a min-depth
-- projection; cycle-free by construction of the seed, safe anyway via depth
-- cap + DISTINCT ON.
CREATE TEMP TABLE q3_neighborhood AS
WITH RECURSIVE hood (center_id, node_kind, node_id, depth) AS (
  SELECT c.id, 'claim', c.id, 0 FROM claims c WHERE c.id = :'K4'
  UNION
  SELECT h.center_id, e.next_kind, e.next_id, h.depth + 1
  FROM hood h
  JOIN LATERAL (
    -- claim -> derivation parents / children / attached evidence / frontier
    SELECT 'claim' AS next_kind, d.parent_claim_id AS next_id
    FROM claim_derivations d
    WHERE h.node_kind = 'claim' AND d.claim_id = h.node_id
    UNION ALL
    SELECT 'claim', d.claim_id
    FROM claim_derivations d
    WHERE h.node_kind = 'claim' AND d.parent_claim_id = h.node_id
    UNION ALL
    SELECT 'evidence', ee.evidence_id
    FROM evidence_edges ee
    WHERE h.node_kind = 'claim' AND ee.claim_id = h.node_id
    UNION ALL
    SELECT 'frontier', f.id
    FROM frontier_entries f
    WHERE h.node_kind = 'claim' AND f.claim_id = h.node_id
    -- evidence -> its source / claims it edges
    UNION ALL
    SELECT 'source', ev.source_id
    FROM evidence ev
    WHERE h.node_kind = 'evidence' AND ev.id = h.node_id
    UNION ALL
    SELECT 'claim', ee2.claim_id
    FROM evidence_edges ee2
    WHERE h.node_kind = 'evidence' AND ee2.evidence_id = h.node_id
  ) e ON true
  WHERE h.depth < 2
)
SELECT DISTINCT ON (node_kind, node_id)
       node_kind, node_id, depth,
       CASE node_kind
         WHEN 'claim'    THEN (SELECT left(canonical_text, 48) FROM claims WHERE id = hood.node_id)
         WHEN 'evidence' THEN (SELECT left(span_text, 48) FROM evidence WHERE id = hood.node_id)
         WHEN 'source'   THEN (SELECT title FROM sources WHERE id = hood.node_id)
         WHEN 'frontier' THEN (SELECT left(need, 48) FROM frontier_entries WHERE id = hood.node_id)
       END AS preview
FROM hood
ORDER BY node_kind, node_id, depth;

SELECT * FROM q3_neighborhood ORDER BY depth, node_kind, node_id;

\echo '=== Q4: dedup candidates via quest lineage (L5 dedup guard) ==='
-- For each claim in a quest, exact canonical-text matches among claims of
-- ANCESTOR quests (from_corpus lineage). The seed's quest-B graft of k4's
-- text is the canonical candidate row. Cross-user candidates never appear:
-- lineage is same-user by composite FK.
CREATE TEMP TABLE q4_dedup_candidates AS
WITH RECURSIVE lineage (quest_id, ancestor_quest_id, depth) AS (
  SELECT q.id, q.source_quest_id, 1
  FROM quests q
  WHERE q.id = :'QB' AND q.source_quest_id IS NOT NULL
  UNION ALL
  SELECT l.quest_id, q2.source_quest_id, l.depth + 1
  FROM lineage l
  JOIN quests q2 ON q2.id = l.ancestor_quest_id
  WHERE q2.source_quest_id IS NOT NULL AND l.depth < 5
)
SELECT mine.quest_id AS quest_id,
       mine.id AS dup_claim_id,
       left(mine.canonical_text, 48) AS canonical_text_prefix,
       l.ancestor_quest_id AS candidate_quest_id,
       theirs.id AS candidate_claim_id,
       l.depth AS lineage_depth
FROM claims mine
JOIN lineage l ON l.quest_id = mine.quest_id
JOIN claims theirs
  ON theirs.quest_id = l.ancestor_quest_id
 AND theirs.canonical_text = mine.canonical_text
 AND theirs.id <> mine.id;

SELECT * FROM q4_dedup_candidates;

\echo '=== cross-consistency: persisted phase mass equals live frontier mass ==='
-- LEFT JOIN + coalesce: a quest whose frontier is fully drained has no row in
-- v_frontier_mass, and its persisted 0/0 snapshot is still consistent.
SELECT p.id AS phase_id, p.frontier_open, p.frontier_mass,
       coalesce(vm.open_entries, 0) AS live_open, coalesce(vm.mass, 0) AS live_mass,
       (p.frontier_open = coalesce(vm.open_entries, 0)
        AND p.frontier_mass = coalesce(vm.mass, 0)) AS consistent
FROM phases p
LEFT JOIN v_frontier_mass vm ON vm.quest_id = p.quest_id
WHERE p.frontier_open IS NOT NULL;

-- ============================================================================
-- Assertions (AC3: each query demonstrably returns >= 1 row; seed graph is
-- L2-clean; phase mass snapshots match live mass).
-- ============================================================================
CREATE TEMP TABLE cq_asserts (
  query text PRIMARY KEY,
  rows integer NOT NULL,
  CONSTRAINT ck_cq_asserts_nonempty CHECK (rows >= 1)
);
INSERT INTO cq_asserts (query, rows) VALUES
  ('Q1_derivation_paths',   (SELECT count(*) FROM q1_derivation_paths)),
  ('Q2_dependent_evidence', (SELECT count(*) FROM q2_dependent_evidence)),
  ('Q3_neighborhood',       (SELECT count(*) FROM q3_neighborhood)),
  ('Q4_dedup_candidates',   (SELECT count(*) FROM q4_dedup_candidates));

CREATE TEMP TABLE cq_zero_asserts (
  query text PRIMARY KEY,
  violations integer NOT NULL,
  CONSTRAINT ck_cq_zero CHECK (violations = 0)
);
INSERT INTO cq_zero_asserts (query, violations) VALUES
  ('Q1V_l2_violations',      (SELECT count(*) FROM q1_l2_violations)),
  ('phase_mass_snapshot_mismatch', (
    SELECT count(*) FROM phases p
    LEFT JOIN v_frontier_mass vm ON vm.quest_id = p.quest_id
    WHERE p.frontier_open IS NOT NULL
      AND (p.frontier_open <> coalesce(vm.open_entries, 0)
           OR p.frontier_mass <> coalesce(vm.mass, 0))));

SELECT * FROM cq_asserts ORDER BY query;
SELECT * FROM cq_zero_asserts ORDER BY query;
