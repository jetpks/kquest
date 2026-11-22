-- ============================================================================
-- kquest I02 cross-quest — canonical queries (queries-i02.sql)
-- ----------------------------------------------------------------------------
-- Executable sketches against the fully seeded database (I01 schema+seed,
-- then schema-i02 + seed-i02), in the proven temp-table style: every family
-- materializes its result into a temp table, then asserts non-emptiness /
-- zero-violations via CHECK-constrained temp tables (AC3). Family M1's
-- near-dup leg is a DESIGNATED SLOT: the SQL shape is pinned here but the
-- embedding tables land in ENTRY 3 (R-036) — match_kind='near_dup' rows in
-- merge_events carry the slot's fixture data meanwhile.
--
--   M1  merge-candidate generation   (exact leg live; near-dup leg slotted)
--   M2  lineage / graft path         (claim -> origin quest chain + corpus)
--   M3  report version chain + standing pointer + stale inventory + imports
--   M4  visibility check             (what a given viewer may read)
--   X1  cross-consistency            (archive drift, closure, mass snapshots)
--   B1  the citation binding pass, run as the designed algorithm (fixture)
-- ============================================================================

-- fixture anchors (ids fixed in seed.sql / seed-i02.sql)
\set CAROL '00000000-0000-4000-8000-000000000003'
\set QA 'b0000000-0000-4000-8000-000000000001'
\set QD 'b0000000-0000-4000-8000-000000000010'
\set D1 'f0000000-0000-4000-8000-000000000101'
\set CC1 '80000000-0000-4000-8000-000000000001'
\set RV2 'aa000000-0000-4000-8000-0000000000b2'
\set SYN2 'd0000000-0000-4000-8000-000000000015'

\echo '=== M1: merge-candidate generation (exactMatch leg live) ==='
-- Leg A — ADOPT candidates: a quest claim whose canonical text exactly
-- matches one of the user's canonical claims, with NO active merge event
-- between them. This is the exactMatch propose-only feed: reversal REOPENS
-- candidacy (k5's reversed event leaves no active lifecycle).
-- Leg B — MINT candidates: same-user claims in >= 2 distinct quests share a
-- canonical text that has NO canonical claim yet: propose minting one.
CREATE TEMP TABLE m1_candidates AS
WITH active_events AS (
  SELECT quest_claim_id, canonical_claim_id
  FROM merge_events
  WHERE state IN ('candidate', 'proposed', 'approved')
), adopt AS (
  SELECT c.user_id,
         'adopt'::text        AS leg,
         c.id                 AS quest_claim_id,
         c.quest_id,
         cc.id                AS canonical_claim_id,
         NULL::uuid           AS peer_claim_id
  FROM claims c
  JOIN canonical_claims cc ON cc.user_id = c.user_id
                          AND cc.canonical_text = c.canonical_text
  LEFT JOIN active_events ae ON ae.quest_claim_id = c.id
                           AND ae.canonical_claim_id = cc.id
  WHERE ae.quest_claim_id IS NULL
), mint AS (
  SELECT a.user_id,
         'mint'::text        AS leg,
         a.id                AS quest_claim_id,
         a.quest_id,
         NULL::uuid          AS canonical_claim_id,
         b.id                AS peer_claim_id
  FROM claims a
  JOIN claims b ON b.user_id = a.user_id
               AND b.canonical_text = a.canonical_text
               AND b.quest_id <> a.quest_id
               AND b.id > a.id
  WHERE NOT EXISTS (SELECT 1 FROM canonical_claims cc
                    WHERE cc.user_id = a.user_id
                      AND cc.canonical_text = a.canonical_text)
)
SELECT * FROM adopt UNION ALL SELECT * FROM mint;

SELECT * FROM m1_candidates ORDER BY leg, quest_claim_id;

-- DESIGNATED SLOT — near-dup leg (ENTRY 3, R-036; wires to the embedding
-- registry tables; shape pinned, tables absent until ENTRY 3):
--   SELECT 'near_dup', c.id, c.quest_id, cc.id, NULL::uuid
--   FROM claims c
--   JOIN claim_embeddings_m<model> ce ON ce.claim_id = c.id
--   JOIN canonical_claims cc ON cc.user_id = c.user_id
--   JOIN canonical_claims_embeddings cce ON cce.canonical_claim_id = cc.id
--   WHERE 1 - (ce.vec <=> cce.vec) >= :near_dup_threshold
--     AND NOT EXISTS (active event between c and cc)
-- Until ENTRY 3 lands, near-dup arrives ONLY as operator/tool-minted
-- merge_events rows with match_kind='near_dup' + similarity (fixture E5).

\echo '=== M2: lineage / graft path (claim -> origin quest chain) ==='
-- Claim-level graft stamps (claims.origin_quest_id) + the quest lineage view
-- (v_quest_lineage) + the corpus-inheritance snapshot (at-init copy).
CREATE TEMP TABLE m2_lineage AS
SELECT c.id            AS claim_id,
       c.quest_seq,
       left(c.canonical_text, 52) AS canonical_text_prefix,
       c.origin_quest_id,
       'claim_graft'::text AS via,
       1               AS depth
FROM claims c
WHERE c.id = :'D1'
UNION ALL
SELECT NULL::uuid, NULL::int, l.ancestor_topic, l.ancestor_quest_id,
       'quest_' || l.via_provenance_kind, l.depth
FROM v_quest_lineage l
WHERE l.quest_id = :'QD';

SELECT * FROM m2_lineage ORDER BY depth;

-- corpus inheritance: the continuation's citable corpus is a subset of the
-- parent's (at-init copy; the parent grew s7 afterwards)
CREATE TEMP TABLE m2_corpus AS
SELECT qs.source_id,
       (qs.quest_id = :'QD') AS in_continuation,
       (qs.quest_id = :'QA') AS in_parent
FROM quest_sources qs
WHERE qs.quest_id IN (:'QD', :'QA')
  AND EXISTS (SELECT 1 FROM sources s
              WHERE s.id = qs.source_id AND s.role = 'citable');

SELECT * FROM m2_corpus ORDER BY source_id;

\echo '=== M3: report version chain + standing pointer + stale inventory ==='
-- The full version chain per quest with graph lineage (synthesis phase +
-- session), model, binding state, standing flag; stale = superseded
-- non-standing versions; imports are the R-027 provenance markers.
CREATE TEMP TABLE m3_report_chain AS
SELECT rv.quest_id,
       rv.version_seq,
       rv.model,
       p.round_no          AS synthesis_round,
       rv.created_session_id,
       rv.standing,
       (rv.bound_at IS NOT NULL) AS bound,
       (SELECT count(*) FROM report_citations rc
         WHERE rc.report_version_id = rv.id)                        AS citations,
       (SELECT count(*) FROM report_citations rc
         WHERE rc.report_version_id = rv.id AND rc.imported)         AS imports,
       (NOT rv.standing)                                             AS stale
FROM report_versions rv
JOIN phases p ON p.id = rv.synthesis_phase_id AND p.quest_id = rv.quest_id
ORDER BY rv.quest_id, rv.version_seq;

SELECT * FROM m3_report_chain;

\echo '=== M4: visibility check (viewer carol) ==='
-- What may a given viewer read: own rows + public door + user grants +
-- workspace grants. Sources now; canonical claims through the SAME
-- mechanism (D6). Private = no grant row.
CREATE TEMP TABLE m4_readable AS
WITH viewer AS (SELECT :'CAROL'::uuid AS v),
own_sources AS (
  SELECT s.id FROM sources s, viewer WHERE s.user_id = viewer.v
), granted_sources AS (
  SELECT rg.source_id
  FROM resource_grants rg, viewer
  WHERE rg.source_id IS NOT NULL
    AND (rg.is_public
      OR rg.grantee_user_id = viewer.v
      OR EXISTS (SELECT 1 FROM workspace_members wm
                 WHERE wm.workspace_id = rg.grantee_workspace_id
                   AND wm.user_id = viewer.v))
), own_cclaims AS (
  SELECT cc.id FROM canonical_claims cc, viewer WHERE cc.user_id = viewer.v
), granted_cclaims AS (
  SELECT rg.canonical_claim_id
  FROM resource_grants rg, viewer
  WHERE rg.canonical_claim_id IS NOT NULL
    AND (rg.is_public
      OR rg.grantee_user_id = viewer.v
      OR EXISTS (SELECT 1 FROM workspace_members wm
                 WHERE wm.workspace_id = rg.grantee_workspace_id
                   AND wm.user_id = viewer.v))
)
SELECT 'source'::text AS resource_kind, id AS resource_id FROM (
  SELECT id FROM own_sources UNION SELECT source_id FROM granted_sources) u
UNION ALL
SELECT 'canonical_claim', id FROM (
  SELECT id FROM own_cclaims UNION SELECT canonical_claim_id FROM granted_cclaims) u2;

SELECT * FROM m4_readable ORDER BY resource_kind, resource_id;

\echo '=== X1: cross-consistency ==='
-- archive drift must be zero; closure contract clean; latest mass snapshots
-- match live mass
CREATE TEMP TABLE x1_checks (
  check_name text PRIMARY KEY,
  violations integer NOT NULL
);
INSERT INTO x1_checks VALUES
 ('archive_drift', (
   SELECT count(*) FROM quest_lifecycle_events e
   JOIN quests q ON q.id = e.quest_id
   WHERE e.to_state = 'archived'
     AND (e.claims_at_archive <> (SELECT count(*) FROM claims c WHERE c.quest_id = e.quest_id)
       OR e.evidence_at_archive <> (SELECT count(*) FROM evidence v WHERE v.quest_id = e.quest_id)
       OR e.frontier_open_at_archive <> (SELECT count(*) FROM frontier_entries f
                                         WHERE f.quest_id = e.quest_id AND f.state = 'open')))),
 ('bare_claims', (SELECT count(*) FROM v_claim_closure WHERE bare)),
 ('latest_mass_snapshot_mismatch', (
   SELECT count(*) FROM (
     SELECT DISTINCT ON (quest_id) quest_id, frontier_open, frontier_mass
     FROM phases
     WHERE frontier_open IS NOT NULL AND ended_at IS NOT NULL
     ORDER BY quest_id, ended_at DESC, id DESC) last
   LEFT JOIN v_frontier_mass vm ON vm.quest_id = last.quest_id
   WHERE last.frontier_open <> coalesce(vm.open_entries, 0)
      OR last.frontier_mass <> coalesce(vm.mass, 0)));

SELECT * FROM x1_checks ORDER BY check_name;

\echo '=== B1: the citation binding pass, run as the designed algorithm ==='
-- Deterministic pass over the fixture report body: inline ordinals -> the
-- quest's citation index (citable corpus ordered by (added_at, source_id))
-- plus the import manifest from the synthesis phase result. The output is
-- the footnote block (human-expanded global anchors). This is R-026 as a
-- running algorithm, not prose. In the product the body comes from object
-- storage through the storage seam; this sketch pins the fixture body as
-- the seam's return value (byte-equal to the rv2 blob; body_sha256 in
-- report_versions is the content hash of exactly this text).
CREATE TEMP TABLE b1_body (body text NOT NULL);
INSERT INTO b1_body VALUES
($fx$The continuation graft re-anchored the beta-control span from the inherited primer [^2] and confirmed modest net-of-cost persistence under the fixture cost assumption [^3]. The parent quest later staged the fixture regulation note [^5], imported here and explicitly marked. Crash clustering remains flagged residual at the per-stock level.$fx$);

-- B1 part 1: derived binding (body ordinals x citation index + manifest) —
-- the pass recomputes what the finalization wrote, proving determinism.
CREATE TEMP TABLE b1_derived AS
WITH ordinals AS (
  SELECT DISTINCT (m[1])::integer AS ordinal
  FROM b1_body, regexp_matches(b1_body.body, '\[\^([0-9]+)\]', 'g') m
), cindex AS (
  SELECT qs.source_id,
         row_number() OVER (ORDER BY qs.added_at, qs.source_id) AS ordinal
  FROM quest_sources qs
  JOIN sources s ON s.id = qs.source_id AND s.user_id = qs.user_id
  WHERE qs.quest_id = :'QD' AND s.role = 'citable'
), manifest AS (
  SELECT (j->>'ordinal')::integer AS ordinal, j->>'source_urn' AS urn,
         (j->>'from_quest')::uuid AS from_quest
  FROM phases p, jsonb_array_elements(p.result->'imports') j
  WHERE p.id = :'SYN2'
)
SELECT o.ordinal,
       s.id AS source_id,
       s.urn,
       (ma.urn IS NOT NULL) AS imported,
       ma.from_quest AS import_source_quest_id
FROM ordinals o
LEFT JOIN cindex ci USING (ordinal)
LEFT JOIN manifest ma USING (ordinal)
JOIN sources s ON s.id = coalesce(ci.source_id,
                                 (SELECT s2.id FROM sources s2 WHERE s2.urn = ma.urn));

SELECT * FROM b1_derived ORDER BY ordinal;

-- B1 part 2: the footnote block (deterministic rendering of the binding)
CREATE TEMP TABLE b1_footnotes AS
SELECT string_agg(
         '[^' || d.ordinal || ']: ' || d.urn || ' — ' || s.title || ', ' || s.canonical_url
           || ', fetched ' || to_char(s.fetched_at, 'YYYY-MM-DD')
           || CASE WHEN d.imported
                   THEN ' [IMPORT from quest ' || d.import_source_quest_id::text || ']'
                   ELSE '' END,
         E'\n' ORDER BY d.ordinal) AS footnote_block
FROM b1_derived d
JOIN sources s ON s.id = d.source_id;

SELECT footnote_block FROM b1_footnotes;

-- ============================================================================
-- Assertions (AC3): each family >= 1 row / satisfies its zero-assertions;
-- the binding pass reproduces the stored citations and the footnote block.
-- ============================================================================
CREATE TEMP TABLE cq2_asserts (
  query text PRIMARY KEY,
  rows integer NOT NULL,
  CONSTRAINT ck_cq2_nonempty CHECK (rows >= 1)
);
INSERT INTO cq2_asserts (query, rows) VALUES
  ('M1_merge_candidates_adopt', (SELECT count(*) FROM m1_candidates WHERE leg = 'adopt')),
  ('M1_merge_candidates_mint',  (SELECT count(*) FROM m1_candidates WHERE leg = 'mint')),
  ('M2_lineage_steps',          (SELECT count(*) FROM m2_lineage)),
  ('M2_corpus_rows',            (SELECT count(*) FROM m2_corpus)),
  ('M3_report_chain_versions',  (SELECT count(*) FROM m3_report_chain)),
  ('M3_stale_inventory',        (SELECT count(*) FROM m3_report_chain WHERE stale)),
  ('M4_readable_resources',     (SELECT count(*) FROM m4_readable)),
  ('B1_derived_bindings',       (SELECT count(*) FROM b1_derived)),
  ('B1_footnote_lines',         (SELECT count(*) FROM regexp_split_to_table(
                                   (SELECT footnote_block FROM b1_footnotes), E'\n')));

CREATE TEMP TABLE cq2_zero_asserts (
  query text PRIMARY KEY,
  violations integer NOT NULL,
  CONSTRAINT ck_cq2_zero CHECK (violations = 0)
);
INSERT INTO cq2_zero_asserts (query, violations) VALUES
 -- candidate generation excludes pairs that already have an ACTIVE event
 -- (fixture: d1 -> CC1 is a standing candidate row, so it must NOT resurface)
 ('M1_active_pairs_excluded', (
   SELECT count(*) FROM m1_candidates
   WHERE quest_claim_id = :'D1' AND canonical_claim_id = :'CC1')),
 -- the reversed merge (k5 -> CC2) has no live canonical member
 ('M1_reversed_not_member', (
   SELECT count(*) FROM v_canonical_members m
   JOIN merge_events e ON e.quest_claim_id = m.quest_claim_id
   WHERE e.state = 'reversed')),
 -- carol cannot read alice's private s2, the user-shared-with-bob s1, or
 -- private s7; and cannot read private canonical CC2/CC3
 ('M4_private_leaks', (
   (SELECT count(*) FROM m4_readable WHERE resource_kind = 'source'
      AND resource_id IN ('a0000000-0000-4000-8000-000000000001',
                          'a0000000-0000-4000-8000-000000000002',
                          'a0000000-0000-4000-8000-000000000007'))
   + (SELECT count(*) FROM m4_readable WHERE resource_kind = 'canonical_claim'
      AND resource_id NOT IN ('80000000-0000-4000-8000-000000000001')))),
 -- X1 cross-consistency all zero
 ('X1_archive_drift',          (SELECT violations FROM x1_checks WHERE check_name = 'archive_drift')),
 ('X1_bare_claims',            (SELECT violations FROM x1_checks WHERE check_name = 'bare_claims')),
 ('X1_mass_snapshot_mismatch', (SELECT violations FROM x1_checks WHERE check_name = 'latest_mass_snapshot_mismatch')),
 -- B1: the recomputed binding equals the stored citations, row for row
 ('B1_binding_matches_stored', (
   SELECT count(*) FROM (
     (SELECT ordinal, source_id FROM b1_derived
        EXCEPT
      SELECT rc.ordinal, coalesce(rc.source_id, rc.imported_source_id)
        FROM report_citations rc WHERE rc.report_version_id = :'RV2')
     UNION ALL
     (SELECT rc.ordinal, coalesce(rc.source_id, rc.imported_source_id)
        FROM report_citations rc WHERE rc.report_version_id = :'RV2'
        EXCEPT
      SELECT ordinal, source_id FROM b1_derived)) d)),
 -- B1: the footnote block contains no unbound ordinal and carries the
 -- IMPORT marker exactly on the imported line
 ('B1_import_marker_shape', (
   SELECT count(*) FROM regexp_split_to_table(
            (SELECT footnote_block FROM b1_footnotes), E'\n') line
   WHERE (line LIKE '[^5]%' AND line NOT LIKE '%[IMPORT from quest %]')
      OR (line NOT LIKE '[^5]%' AND line LIKE '%[IMPORT%]')));

SELECT * FROM cq2_asserts ORDER BY query;
SELECT * FROM cq2_zero_asserts ORDER BY query;
