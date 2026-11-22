-- ============================================================================
-- kquest I02 cross-quest — canonical queries (queries-i02.sql)
-- ----------------------------------------------------------------------------
-- Executable sketches against the fully seeded database (I01 schema+seed,
-- then schema-i02 + seed-i02), in the proven temp-table style: every family
-- materializes its result into a temp table, then asserts non-emptiness /
-- zero-violations via CHECK-constrained temp tables (AC3). Amended
-- 2026-11-22 per the operator rulings: M1 is now the HUB VIEW's query
-- surface (DR-16 — the hub is derived, no merge workflow exists), and M3
-- carries the FINGERPRINT drift inventory (DR-17 — staleness detected, not
-- prevented). Near-dup remains a DESIGNATED SLOT: the SQL shape for
-- embedding-scored candidates is pinned here but the embedding tables land
-- in ENTRY 3 (R-036).
--
--   M1  hub view queries            (exact-text reuse lookup + type
--                                    divergence surfacing — the tripwire data)
--   M2  lineage / graft path        (claim -> origin quest chain + corpus)
--   M3  report version chain + pinned fingerprints + stale inventory
--   M4  visibility check            (what a given viewer may read)
--   X1  cross-consistency           (archive recording, closure, mass snapshots)
--   B1  the citation binding pass, run as the designed algorithm (fixture)
-- ============================================================================

-- fixture anchors (ids fixed in seed.sql / seed-i02.sql)
\set CAROL '00000000-0000-4000-8000-000000000003'
\set QA 'b0000000-0000-4000-8000-000000000001'
\set QD 'b0000000-0000-4000-8000-000000000010'
\set D1 'f0000000-0000-4000-8000-000000000101'
\set RV2 'aa000000-0000-4000-8000-0000000000b2'
\set SYN2 'd0000000-0000-4000-8000-000000000015'

\echo '=== M1: the hub view — exact-text reuse lookup + type-divergence surfacing ==='
-- The hub is a DERIVED view (DR-16): identity = (user_id, canonical_text,
-- terminal_type); exact canonical-text derivation (DR-02 option A, ruled);
-- nothing adopted, nothing refused.
--
-- Leg 1 — REUSE LOOKUP: what does a given quest already know? For each
-- claim of the focus quest, the hub entries sharing its canonical text that
-- hold members in OTHER quests (prior derivations of the same line).
CREATE TEMP TABLE m1_reuse AS
SELECT c.id            AS quest_claim_id,
       left(v.canonical_text, 52) AS canonical_text_prefix,
       v.terminal_type,
       v.member_claim_ids,
       v.quest_count,
       (SELECT count(*) FROM unnest(v.member_claim_ids) m
          JOIN claims c2 ON c2.id = m AND c2.quest_id <> c.quest_id) AS prior_members
FROM claims c
JOIN v_canonical_claims v
  ON v.user_id = c.user_id
 AND v.canonical_text = c.canonical_text
WHERE c.quest_id = :'QD'
  AND EXISTS (SELECT 1 FROM claims c2
              WHERE c2.user_id = c.user_id
                AND c2.canonical_text = c.canonical_text
                AND c2.quest_id <> c.quest_id);

SELECT * FROM m1_reuse ORDER BY quest_claim_id, terminal_type NULLS FIRST;

-- Leg 2 — TYPE-DIVERGENCE SURFACING: hub entries whose (user, text) carries
-- more than one distinct non-null terminal_type. These coexist as distinct
-- entries (never merged, never refused) and are the ENTRY 7 tripwire's data:
-- same canonical text, conflicting typed terminals, adjudicated in the
-- source quest (the hub is derived — it holds no state to fix).
CREATE TEMP TABLE m1_divergence AS
SELECT user_id,
       canonical_text,
       terminal_type,
       member_claim_ids,
       quest_count,
       first_seen,
       latest_seen
FROM v_canonical_claims
WHERE type_divergent;

SELECT * FROM m1_divergence ORDER BY canonical_text, terminal_type;

-- DESIGNATED SLOT — near-dup leg (ENTRY 3, R-036; wires to the embedding
-- registry tables; shape pinned, tables absent until ENTRY 3):
--   SELECT 'near_dup', c.id, c.quest_id, v.canonical_text, v.terminal_type
--   FROM claims c
--   JOIN claim_embeddings_m<model> ce ON ce.claim_id = c.id
--   JOIN v_canonical_claims v ON v.user_id = c.user_id
--    AND v.canonical_text <> c.canonical_text
--   WHERE 1 - (ce.vec <=> convert_to(c.canonical_text embedding lookup))
--         >= :near_dup_threshold
-- Until ENTRY 3 lands, near-dup is visible only as text pairs the operator
-- can eyeball (the seed keeps d3's near-duplicate wording of quest A's k5
-- as the slot's fixture example).

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

\echo '=== M3: report version chain + pinned fingerprints + stale inventory ==='
-- The full version chain per quest with graph lineage (synthesis phase +
-- session), model, binding state, standing flag, and the PINNED quest
-- fingerprint (DR-17: the graph fingerprint at synthesis time). A version
-- whose pin differs from the LIVE fingerprint (v_quest_graph_fingerprint)
-- is STALE — the staleness tripwire's inventory. Fixture: v1/v2 pin the
-- archived graph and are stale after the post-archive revisit; v3 pins the
-- reworked graph and is clean (but not yet standing — finalization pending).
CREATE TEMP TABLE m3_report_chain AS
SELECT rv.quest_id,
       rv.version_seq,
       rv.model,
       p.round_no          AS synthesis_round,
       rv.created_session_id,
       rv.quest_fingerprint,
       fp.graph_fingerprint AS live_fingerprint,
       rv.standing,
       (rv.bound_at IS NOT NULL) AS bound,
       (SELECT count(*) FROM report_citations rc
         WHERE rc.report_version_id = rv.id)                        AS citations,
       (SELECT count(*) FROM report_citations rc
         WHERE rc.report_version_id = rv.id AND rc.imported)         AS imports,
       (rv.quest_fingerprint <> fp.graph_fingerprint)               AS stale_fingerprint,
       (NOT rv.standing)                                             AS superseded
FROM report_versions rv
JOIN phases p ON p.id = rv.synthesis_phase_id AND p.quest_id = rv.quest_id
JOIN v_quest_graph_fingerprint fp ON fp.quest_id = rv.quest_id
ORDER BY rv.quest_id, rv.version_seq;

SELECT * FROM m3_report_chain;

-- the same drift detector over ARCHIVE rows: pinned-at-freeze fingerprint
-- versus the live graph (the post-archive rework fixture trips it)
CREATE TEMP TABLE m3_archive_drift AS
SELECT e.quest_id,
       e.graph_fingerprint,
       fp.graph_fingerprint AS live_fingerprint,
       e.claims_at_archive,
       (SELECT count(*) FROM claims c WHERE c.quest_id = e.quest_id) AS live_claims,
       (e.graph_fingerprint <> fp.graph_fingerprint)                AS drifted
FROM quest_lifecycle_events e
JOIN v_quest_graph_fingerprint fp ON fp.quest_id = e.quest_id
WHERE e.to_state = 'archived';

SELECT * FROM m3_archive_drift;

\echo '=== M4: visibility check (viewer carol) ==='
-- What may a given viewer read: own rows + public door + user grants +
-- workspace grants. Sources now; the canonical-claim grant kind is deferred
-- with the materialized hub (DR-16). Private = no grant row.
CREATE TEMP TABLE m4_readable AS
WITH viewer AS (SELECT :'CAROL'::uuid AS v),
own_sources AS (
  SELECT s.id FROM sources s, viewer WHERE s.user_id = viewer.v
), granted_sources AS (
  SELECT rg.source_id
  FROM resource_grants rg, viewer
  WHERE rg.is_public
     OR rg.grantee_user_id = viewer.v
     OR EXISTS (SELECT 1 FROM workspace_members wm
                WHERE wm.workspace_id = rg.grantee_workspace_id
                  AND wm.user_id = viewer.v)
)
SELECT 'source'::text AS resource_kind, id AS resource_id FROM (
  SELECT id FROM own_sources UNION SELECT source_id FROM granted_sources) u;

SELECT * FROM m4_readable ORDER BY resource_kind, resource_id;

\echo '=== X1: cross-consistency ==='
-- archive rows record their fingerprints; closure contract clean; latest
-- mass snapshots match live mass
CREATE TEMP TABLE x1_checks (
  check_name text PRIMARY KEY,
  violations integer NOT NULL
);
INSERT INTO x1_checks VALUES
 ('archive_fingerprint_recorded', (
   SELECT count(*) FROM quest_lifecycle_events e
   WHERE e.to_state = 'archived'
     AND (e.graph_fingerprint IS NULL
       OR e.graph_fingerprint::text !~ '^[0-9a-f]{64}$'
       OR NOT EXISTS (SELECT 1 FROM phases p
                      WHERE p.id = e.verification_phase_id
                        AND p.kind = 'verification' AND p.state = 'complete')))),
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
  ('M1_reuse_lookup',           (SELECT count(*) FROM m1_reuse)),
  ('M1_type_divergence',        (SELECT count(*) FROM m1_divergence)),
  ('M2_lineage_steps',          (SELECT count(*) FROM m2_lineage)),
  ('M2_corpus_rows',            (SELECT count(*) FROM m2_corpus)),
  ('M3_report_chain_versions',  (SELECT count(*) FROM m3_report_chain)),
  ('M3_fingerprint_stale',      (SELECT count(*) FROM m3_report_chain WHERE stale_fingerprint)),
  ('M3_fingerprint_clean_pin',  (SELECT count(*) FROM m3_report_chain WHERE NOT stale_fingerprint)),
  ('M3_archive_fingerprint_drift', (SELECT count(*) FROM m3_archive_drift WHERE drifted)),
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
 -- the hub covers every claim exactly once: nothing adopted, nothing refused
 ('M1_hub_covers_every_claim_once', (
   SELECT count(*) FROM claims c
   WHERE (SELECT count(*) FROM v_canonical_claims v
          WHERE v.user_id = c.user_id
            AND v.canonical_text = c.canonical_text
            AND c.id = ANY (v.member_claim_ids)) <> 1)),
 -- the reuse fixture's shape: the unterminated beta-control entry groups
 -- exactly k4 (quest A) + k11 (quest B); d1 keeps its own typed entry
 ('M1_same_type_group_shape', (
   SELECT count(*) FROM v_canonical_claims v
   WHERE v.canonical_text = 'Momentum profits persist after controlling for market beta in the fixture literature.'
     AND (   (v.terminal_type IS NULL
              AND (v.quest_count <> 2
                   OR v.member_claim_ids <> ARRAY['f0000000-0000-4000-8000-000000000004'::uuid,
                                                  'f0000000-0000-4000-8000-000000000011'::uuid]))
          OR (v.terminal_type = 'primary-empirical'
              AND v.member_claim_ids <> ARRAY['f0000000-0000-4000-8000-000000000101'::uuid])
          OR (v.terminal_type IS NULL AND v.type_divergent)))),
 -- the divergence fixture's shape: exactly two plateau entries (k8 primary,
 -- d4 residual), both flagged
 ('M1_divergence_shape', (
   (SELECT count(*) FROM v_canonical_claims v
    WHERE v.canonical_text = 'Momentum returns plateau at the twelve-month horizon in the fixture sample.'
      AND ((v.terminal_type = 'primary-empirical'
            AND (v.member_claim_ids <> ARRAY['f0000000-0000-4000-8000-000000000008'::uuid]
                 OR NOT v.type_divergent))
        OR (v.terminal_type = 'residual-uncertainty'
            AND (v.member_claim_ids <> ARRAY['f0000000-0000-4000-8000-000000000104'::uuid]
                 OR NOT v.type_divergent))
        OR v.terminal_type IS NULL))
   + CASE WHEN (SELECT count(*) FROM v_canonical_claims
                WHERE canonical_text = 'Momentum returns plateau at the twelve-month horizon in the fixture sample.') = 2
          THEN 0 ELSE 1 END)),
 -- carol cannot read alice's private s2, the user-shared-with-bob s1, or
 -- private s7
 ('M4_private_leaks', (
   SELECT count(*) FROM m4_readable
   WHERE resource_id IN ('a0000000-0000-4000-8000-000000000001',
                         'a0000000-0000-4000-8000-000000000002',
                         'a0000000-0000-4000-8000-000000000007'))),
 -- X1 cross-consistency all zero
 ('X1_archive_fingerprint_recorded', (SELECT violations FROM x1_checks WHERE check_name = 'archive_fingerprint_recorded')),
 ('X1_bare_claims',                   (SELECT violations FROM x1_checks WHERE check_name = 'bare_claims')),
 ('X1_mass_snapshot_mismatch',        (SELECT violations FROM x1_checks WHERE check_name = 'latest_mass_snapshot_mismatch')),
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
