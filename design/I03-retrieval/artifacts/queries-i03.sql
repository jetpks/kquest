-- ============================================================================
-- kquest I03 retrieval — the hybrid prototype (queries-i03.sql)
-- ----------------------------------------------------------------------------
-- Executable query families against the fully seeded database (I01
-- schema+seed, I02 schema-i02+seed-i02, schema-i03 + seed-i03), in the
-- proven temp-table style: every family materializes results, then asserts
-- non-emptiness / zero-violations / ordering facts via a CHECK-constrained
-- temp table. Applied with psql -v ON_ERROR_STOP=1; any assertion failure
-- aborts the run (AC3).
--
-- Five families (Specification):
--   (a) DENSE leg   — cosine via pgvector <=> on the GENERATED table
--                     (user-scoped, quest-scoped, cross-user probe, A/B)
--   (b) FTS leg     — tsquery over chunks.search_tsv (generated column)
--   (c) RRF FUSION  — (a)+(b) fused by rank; THE FORMULA IS THE SQL
--   (d) DEDUP       — dedup-by-construction candidate check (exact leg +
--                     near-dup vector leg + the I02 hub seam)
--   (e) MECHANICAL RELEVANCE — need-text vs topic questions (I20)
--
-- Registry-only law (D4): NO model name appears in this file. Models are
-- addressed by registry id constants (\set M1/M2) and by their GENERATED
-- table names (emb_bge_m3_1024 / emb_minilm_ab_384) — the sanctioned
-- exception, because the table name IS registry-derived data. The
-- synthetic query vectors are computed by the same deterministic
-- sha256-derived encoder as the seed (DR-15): identical texts yield
-- identical vectors (distance exactly 0), related texts rank by shared
-- topic vocabulary. This proves the QUERY machinery, never model quality.
--
-- Per-user scoping is demonstrated ON EVERY LEG (the :USER substitution is
-- a parameter of the query object, not a property of the data): family (a)
-- runs alice- and bob-scoped variants; (b) includes a bob-scoped probe;
-- (c) fuses user-scoped legs; (d) runs the candidate check both ways; (e)
-- scores one user's open needs.
-- ============================================================================

-- fixture anchors (fixed ids: I01/I02 seeds + seed-i03.sql)
\set ALICE '00000000-0000-4000-8000-000000000001'
\set BOB   '00000000-0000-4000-8000-000000000002'
\set QA    'b0000000-0000-4000-8000-000000000001'
\set QB    'b0000000-0000-4000-8000-000000000002'
\set QD    'b0000000-0000-4000-8000-000000000010'
-- S3: the costs note (citable, alice); M1/M2: registry rows (active dense
-- 1024d / active A/B 384d); JOB_REEMBED: the running re-embed generation
\set S3    'a0000000-0000-4000-8000-000000000003'
\set M1    '92000000-0000-4000-8000-000000000001'
\set M2    '92000000-0000-4000-8000-000000000002'
\set JOB_REEMBED '91000000-0000-4000-8000-000000000006'

-- ---------------------------------------------------------------------------
-- The deterministic synthetic-vector encoder (same function as seed-i03;
-- DR-15 methodology and limits stated there and in DESIGN §14).
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.synth_vec(t text, dims integer) RETURNS vector
LANGUAGE sql IMMUTABLE AS $fn$
WITH toks AS (
  SELECT w AS tok
  FROM unnest(regexp_split_to_array(lower(coalesce(t, '')), '[^a-z0-9]+')) AS w
  WHERE char_length(w) >= 3
    AND w NOT IN ('the','and','for','with','that','this','from','are','was',
                  'its','not','but','how','which','under','after','once',
                  'about','into','over','fixture','text','synthesized',
                  'kquest','seed','quotes','real','source','note','primer',
                  'literature','sample','remains','roughly','while','between')
), blocks AS (
  SELECT tok, b, sha256(convert_to(tok, 'UTF8') || int4send(b)) AS h
  FROM toks CROSS JOIN generate_series(0, (dims - 1) / 8) AS b
), dirs AS (
  SELECT blk.b * 8 + j AS i,
         ((get_byte(blk.h, j * 4)::bigint * 16777216
          + get_byte(blk.h, j * 4 + 1)::bigint * 65536
          + get_byte(blk.h, j * 4 + 2)::bigint * 256
          + get_byte(blk.h, j * 4 + 3)::bigint
          )::double precision - 2147483648.0) / 2147483648.0 AS x
  FROM blocks blk CROSS JOIN generate_series(0, 7) AS j
  WHERE blk.b * 8 + j < dims
), sums AS (SELECT i, sum(x) AS s FROM dirs GROUP BY i),
norm AS (SELECT sqrt(sum(s * s)) AS n FROM sums)
SELECT ('[' || string_agg(to_char(s.s / nullif(n.n, 0), 'FM0.00000000'), ',' ORDER BY s.i)
        || ']')::vector
FROM sums s CROSS JOIN norm n
$fn$;

CREATE TEMP TABLE q03_asserts (
  check_name text PRIMARY KEY,
  ok boolean NOT NULL
);

\echo '=== corpus pipeline state (R-031: progress-tracked jobs, resumable cursor) ==='
SELECT j.state, j.kind, count(*) AS jobs, sum(j.done_items) AS items_done
FROM embed_jobs j
WHERE j.user_id = :'ALICE'
GROUP BY j.state, j.kind ORDER BY j.state, j.kind;

SELECT j.id, j.state, (j.done_items || '/' || j.total_items) AS cursor, j.idem_key
FROM embed_jobs j WHERE j.id = :'JOB_REEMBED';

-- ============================================================================
-- (a) DENSE LEG — cosine distance via pgvector <=> on the generated table.
--     The query vector is computed server-side by the same deterministic
--     encoder that produced the stored vectors (DR-15); in production this
--     is ONE fast-embeddings wire call per query text (R-034), cached by
--     the query seam — never a model name in the query.
-- ============================================================================
\echo '=== (a) dense leg: user-scoped cosine search over chunks ==='
-- Query text chosen to have a known top hit: the costs-note paragraph that
-- shares the query's topic vocabulary (transaction / costs / momentum /
-- spread).
CREATE TEMP TABLE qa_dense AS
SELECT c.id AS chunk_id, s.urn, left(c.text, 58) AS chunk_prefix,
       (e.embedding <=> pg_temp.synth_vec(
          'transaction costs consume the gross momentum spread', 1024)) AS cos_dist
FROM emb_bge_m3_1024 e
JOIN chunks c  ON c.id = e.chunk_id
JOIN sources s ON s.id = c.source_id
WHERE e.user_id = :'ALICE'          -- PER-USER SCOPING (every leg)
  AND e.target_kind = 'chunk'
ORDER BY e.embedding <=> pg_temp.synth_vec(
            'transaction costs consume the gross momentum spread', 1024), c.id
LIMIT 8;

SELECT * FROM qa_dense;

INSERT INTO q03_asserts (check_name, ok) VALUES
  ('a: dense leg returns >= 3 rows',            (SELECT count(*) >= 3 FROM qa_dense)),
  ('a: top-1 is the costs-note paragraph',      (SELECT src = :'S3' FROM (
                                                   SELECT d.cos_dist, d.chunk_id, c.source_id AS src
                                                   FROM qa_dense d JOIN chunks c ON c.id = d.chunk_id
                                                   ORDER BY d.cos_dist, d.chunk_id LIMIT 1) top)),
  ('a: top-1 cosine distance < 0.4',            (SELECT cos_dist < 0.4
                                                 FROM qa_dense ORDER BY cos_dist, chunk_id LIMIT 1)),
  ('a: top-1 clearly ahead of runner-up',       (SELECT (
                                                   SELECT cos_dist FROM qa_dense ORDER BY cos_dist, chunk_id LIMIT 1)
                                                 < (
                                                   SELECT cos_dist FROM qa_dense ORDER BY cos_dist, chunk_id OFFSET 1 LIMIT 1)));

\echo '=== (a2) dense leg: QUEST-scoped variant (quest A corpus only) ==='
CREATE TEMP TABLE qa_dense_quest AS
SELECT c.id AS chunk_id, s.urn,
       (e.embedding <=> pg_temp.synth_vec(
          'transaction costs consume the gross momentum spread', 1024)) AS cos_dist
FROM emb_bge_m3_1024 e
JOIN chunks c  ON c.id = e.chunk_id
JOIN sources s ON s.id = c.source_id
JOIN quest_sources qs ON qs.source_id = c.source_id AND qs.quest_id = :'QA'
WHERE e.user_id = :'ALICE'
  AND e.target_kind = 'chunk'
ORDER BY e.embedding <=> pg_temp.synth_vec(
            'transaction costs consume the gross momentum spread', 1024), c.id;

SELECT * FROM qa_dense_quest;

INSERT INTO q03_asserts (check_name, ok) VALUES
  ('a2: quest-scoped dense leg non-empty',        (SELECT count(*) >= 1 FROM qa_dense_quest)),
  ('a2: every hit is in the quest corpus',        (SELECT count(*) = 0 FROM qa_dense_quest h
                                                   WHERE NOT EXISTS (
                                                     SELECT 1 FROM quest_sources qs
                                                     JOIN chunks c ON c.source_id = qs.source_id
                                                     WHERE c.id = h.chunk_id
                                                       AND qs.quest_id = :'QA')));

\echo '=== (a3) dense leg: CROSS-USER PROBE — the same query as BOB ==='
-- bob has vectors (his own claim) but NO chunk vectors: his scoped dense
-- search over chunks returns NOTHING. Tenancy is a property of the query
-- object, proven here: alice's corpus is invisible to bob's search.
CREATE TEMP TABLE qa_dense_bob AS
SELECT c.id AS chunk_id,
       (e.embedding <=> pg_temp.synth_vec(
          'transaction costs consume the gross momentum spread', 1024)) AS cos_dist
FROM emb_bge_m3_1024 e
JOIN chunks c ON c.id = e.chunk_id
WHERE e.user_id = :'BOB'
  AND e.target_kind = 'chunk'
  AND e.embedding <=> pg_temp.synth_vec(
        'transaction costs consume the gross momentum spread', 1024) < 0.9;

SELECT count(*) AS bob_chunk_hits FROM qa_dense_bob;

INSERT INTO q03_asserts (check_name, ok) VALUES
  ('a3: cross-user dense probe returns NOTHING', (SELECT count(*) = 0 FROM qa_dense_bob));

\echo '=== (a4) A/B: the same query family on the SECOND registry model ==='
-- Model choice is DATA: the registry id (and the generated table it maps
-- to) is the only difference between these two queries. Two active models
-- coexist; queries pick by id; zero code change (R-029 register/A-B law).
-- The beta-control query shares its content-token set with the canonical
-- text of the beta-control family (k4/k11/d1), so both models return it at
-- distance ~0 — the encoder's exact-set property (DR-15).
CREATE TEMP TABLE qa_ab_m1 AS
SELECT 'm1' AS leg, c.quest_seq, left(c.canonical_text, 46) AS claim,
       (e.embedding <=> pg_temp.synth_vec(
          'momentum profits persist after controlling for market beta', 1024)) AS cos_dist
FROM emb_bge_m3_1024 e
JOIN claims c ON c.id = e.claim_id
WHERE e.user_id = :'ALICE' AND e.model_id = :'M1'
ORDER BY e.embedding <=> pg_temp.synth_vec(
           'momentum profits persist after controlling for market beta', 1024), c.id
LIMIT 3;

CREATE TEMP TABLE qa_ab_m2 AS
SELECT 'm2' AS leg, c.quest_seq, left(c.canonical_text, 46) AS claim,
       (e.embedding <=> pg_temp.synth_vec(
          'momentum profits persist after controlling for market beta', 384)) AS cos_dist
FROM emb_minilm_ab_384 e
JOIN claims c ON c.id = e.claim_id
WHERE e.user_id = :'ALICE' AND e.model_id = :'M2'
ORDER BY e.embedding <=> pg_temp.synth_vec(
           'momentum profits persist after controlling for market beta', 384), c.id
LIMIT 3;

SELECT * FROM qa_ab_m1 UNION ALL SELECT * FROM qa_ab_m2;

INSERT INTO q03_asserts (check_name, ok) VALUES
  ('a4: both registry models answer (A/B is data)', ((SELECT count(*) FROM qa_ab_m1) = 3
                                                      AND (SELECT count(*) FROM qa_ab_m2) = 3)),
  ('a4: m1 top-1 is the beta-control claim (seq 4)', (SELECT quest_seq = 4 FROM qa_ab_m1
                                                      ORDER BY cos_dist LIMIT 1)),
  ('a4: m2 top-1 is the beta-control claim (seq 4)', (SELECT quest_seq = 4 FROM qa_ab_m2
                                                      ORDER BY cos_dist LIMIT 1)),
  ('a4: exact content-token-set match -> distance ~0', (SELECT count(*) FILTER (WHERE cos_dist >= 0.01) = 0 FROM (
                                                         (SELECT cos_dist FROM qa_ab_m1 ORDER BY cos_dist LIMIT 1)
                                                         UNION ALL
                                                         (SELECT cos_dist FROM qa_ab_m2 ORDER BY cos_dist LIMIT 1)) t));

-- ============================================================================
-- (b) FTS LEG — the lexical half of the hybrid (R-032). PG full-text over
--     the GENERATED tsvector column (schema-i03): plainto_tsquery ANDs the
--     terms; ts_rank orders. This leg is the BM25 slot's day-one occupant
--     (DR-09): when BM25 lands it replaces the RANKING inside this leg —
--     RRF consumes ranks only, so fusion does not change.
-- ============================================================================
\echo '=== (b) FTS leg: tsquery over generated tsvector (user-scoped) ==='
CREATE TEMP TABLE qb_fts AS
SELECT c.id AS chunk_id, s.urn, left(c.text, 58) AS chunk_prefix,
       ts_rank(c.search_tsv, q.query) AS fts_rank
FROM chunks c
JOIN sources s ON s.id = c.source_id
CROSS JOIN LATERAL (SELECT plainto_tsquery('english',
                     'momentum costs') AS query) q
WHERE c.user_id = :'ALICE'          -- PER-USER SCOPING (every leg)
  AND c.search_tsv @@ q.query
ORDER BY ts_rank(c.search_tsv, q.query) DESC, c.id;

SELECT * FROM qb_fts;

-- BOB-scoped FTS probe: bob has no chunks at all -> nothing (scoping is
-- structural: his tenancy owns no rows in this family)
CREATE TEMP TABLE qb_fts_bob AS
SELECT c.id
FROM chunks c
WHERE c.user_id = :'BOB'
  AND c.search_tsv @@ plainto_tsquery('english', 'momentum costs');

SELECT count(*) AS bob_fts_hits FROM qb_fts_bob;

INSERT INTO q03_asserts (check_name, ok) VALUES
  ('b: FTS leg returns >= 3 rows',        (SELECT count(*) >= 3 FROM qb_fts)),
  ('b: FTS ranks strictly ordered',       (SELECT count(*) = 0 FROM (
                                             SELECT fts_rank, lag(fts_rank) OVER (ORDER BY fts_rank DESC, chunk_id) AS prev
                                             FROM qb_fts) w
                                           WHERE prev IS NOT NULL AND fts_rank > prev)),
  ('b: every hit matched the tsquery',    (SELECT count(*) = 0 FROM qb_fts h
                                           JOIN chunks c ON c.id = h.chunk_id
                                           WHERE NOT c.search_tsv @@ plainto_tsquery('english', 'momentum costs'))),
  ('b: cross-user FTS probe returns NOTHING', (SELECT count(*) = 0 FROM qb_fts_bob));

-- ============================================================================
-- (c) RRF FUSION — rank-based fusion of (a)+(b). THE FORMULA, VISIBLE:
--
--        rrf(d) = w_dense * 1/(K + rank_dense(d))  +  w_fts * 1/(K + rank_fts(d))
--
--     with K = 60, w_dense = w_fts = 1.0 (D4's ruling; rank-based fusion
--     sidesteps the score-scale mismatch between cosine distance, ts_rank,
--     and any future BM25/SPLADE score — the BM25 slot swaps the lexical
--     leg's RANKING, not the fusion). A document absent from a leg
--     contributes 0 from that leg. Ranks are 1-based, from row_number()
--     over each leg's own ORDER BY (deterministic tiebreaks: chunk id).
--     Both legs are PER-USER scoped and here also QUEST-scoped (the
--     corpus of quest A).
-- ============================================================================
\echo '=== (c) RRF fusion of dense + FTS legs (quest A corpus) ==='
-- leg 1: dense ranks (cosine distance ASC)
CREATE TEMP TABLE qc_leg_dense AS
SELECT c.id AS chunk_id,
       row_number() OVER (ORDER BY e.embedding <=>
             pg_temp.synth_vec('momentum costs', 1024), c.id) AS rnk
FROM emb_bge_m3_1024 e
JOIN chunks c ON c.id = e.chunk_id
WHERE e.user_id = :'ALICE' AND e.target_kind = 'chunk'
  AND EXISTS (SELECT 1 FROM quest_sources qs
              WHERE qs.source_id = c.source_id AND qs.quest_id = :'QA')
ORDER BY e.embedding <=> pg_temp.synth_vec('momentum costs', 1024), c.id;

-- leg 2: FTS ranks (ts_rank DESC)
CREATE TEMP TABLE qc_leg_fts AS
SELECT c.id AS chunk_id,
       row_number() OVER (ORDER BY ts_rank(c.search_tsv,
             plainto_tsquery('english', 'momentum costs')) DESC, c.id) AS rnk
FROM chunks c
WHERE c.user_id = :'ALICE'
  AND c.search_tsv @@ plainto_tsquery('english', 'momentum costs')
  AND EXISTS (SELECT 1 FROM quest_sources qs
              WHERE qs.source_id = c.source_id AND qs.quest_id = :'QA')
ORDER BY ts_rank(c.search_tsv, plainto_tsquery('english', 'momentum costs')) DESC, c.id;

-- fusion: FULL OUTER UNION of the legs, formula applied per row
CREATE TEMP TABLE qc_fused AS
SELECT coalesce(d.chunk_id, f.chunk_id) AS chunk_id,
       s.urn, left(c.text, 52) AS chunk_prefix,
       d.rnk AS dense_rank, f.rnk AS fts_rank,
       -- *** the RRF formula, K = 60, weights 1.0 (see header) ***
       (CASE WHEN d.rnk IS NOT NULL THEN 1.0 / (60 + d.rnk) ELSE 0 END)
     + (CASE WHEN f.rnk IS NOT NULL THEN 1.0 / (60 + f.rnk) ELSE 0 END) AS rrf
FROM qc_leg_dense d
FULL OUTER JOIN qc_leg_fts f ON f.chunk_id = d.chunk_id
JOIN chunks  c ON c.id = coalesce(d.chunk_id, f.chunk_id)
JOIN sources s ON s.id = c.source_id
ORDER BY rrf DESC,
         coalesce(d.rnk, 1000000) + coalesce(f.rnk, 1000000) ASC,
         coalesce(d.chunk_id, f.chunk_id) ASC;

SELECT * FROM qc_fused LIMIT 8;

INSERT INTO q03_asserts (check_name, ok) VALUES
  ('c: fused set is the UNION of the legs',  (SELECT count(*) = (
                                                SELECT count(*) FROM (
                                                  SELECT chunk_id FROM qc_leg_dense
                                                  UNION SELECT chunk_id FROM qc_leg_fts) u)
                                              FROM qc_fused)),
  ('c: top-3 fused hits appear in BOTH legs', (SELECT count(*) = 3 FROM (
                                                SELECT * FROM qc_fused
                                                ORDER BY rrf DESC,
                                                         coalesce(dense_rank, 1000000) + coalesce(fts_rank, 1000000) ASC,
                                                         chunk_id ASC
                                                LIMIT 3) top
                                               WHERE dense_rank IS NOT NULL AND fts_rank IS NOT NULL)),
  ('c: a both-legs hit outranks any single-leg hit', (
                 SELECT (SELECT min(rrf) FROM qc_fused
                          WHERE dense_rank IS NOT NULL AND fts_rank IS NOT NULL)
                      > (SELECT max(rrf) FROM qc_fused
                          WHERE dense_rank IS NULL OR fts_rank IS NULL))),
  ('c: every rrf value equals the formula recomputed', (SELECT count(*) = 0 FROM qc_fused
                                                    WHERE rrf <> (CASE WHEN dense_rank IS NOT NULL
                                                                       THEN 1.0 / (60 + dense_rank) ELSE 0 END)
                                                                   + (CASE WHEN fts_rank IS NOT NULL
                                                                       THEN 1.0 / (60 + fts_rank) ELSE 0 END))),
  ('c: legs disagree on order (fusion is doing work)', (
                 SELECT (SELECT array_agg(chunk_id ORDER BY rnk) FROM qc_leg_dense WHERE rnk <= 3)
                     <> (SELECT array_agg(chunk_id ORDER BY rnk) FROM qc_leg_fts  WHERE rnk <= 3)));

-- ============================================================================
-- (d) DEDUP-BY-CONSTRUCTION — the tool-side candidate check at claim
--     creation (R-036). Two legs, one result set:
--       exact  — canonical_text byte-equality (the I01 DR-05 generated
--                normalizer; today's whole hub surface, I02 M1)
--       near   — cosine neighbors in the registry's CLAIM vectors, within
--                the USER's scope (the hub is per-user, D3/D6)
--     The result maps onto v_canonical_claims entries — THE SEAM to I02's
--     DR-16 growth slot: match_kind='near_dup' is the slot's data, surfaced
--     to the creating tool, adjudicated in quests (the hub stays derived).
--     This retires the model-discipline dedup search-cap law (the PoC's
--     one-search-per-candidate rule was blown through in synthesis —
--     arc-run-20261122T-llm-trading-midarc §4; the structural fix is a
--     tool-side check, not a law).
-- ============================================================================
\echo '=== (d) dedup: exact leg CANNOT see the near-duplicate ==='
-- probe: a NEW claim text about to be created — deliberately near-duplicate
-- wording of k5/d3 (the I02-designated near-dup family), not an exact match
CREATE TEMP TABLE qd_probe (probe_text text NOT NULL);
INSERT INTO qd_probe VALUES
  ('Net-of-cost momentum persists modestly once the cost assumptions are applied.');

CREATE TEMP TABLE qd_exact AS
SELECT c.id AS claim_id, c.quest_id, c.canonical_text
FROM claims c, qd_probe p
WHERE c.user_id = :'ALICE'
  AND c.canonical_text = btrim(regexp_replace(normalize(p.probe_text, NFC),
                                              '[ \t\n\r\f\v]+', ' ', 'g'),
                               ' ' || chr(9) || chr(10) || chr(13) || chr(11) || chr(12));

SELECT count(*) AS exact_matches FROM qd_exact;

\echo '=== (d) dedup: near-dup vector leg (top-5, user-scoped) ==='
CREATE TEMP TABLE qd_near AS
SELECT c.id AS claim_id, c.quest_id, c.quest_seq,
       left(c.canonical_text, 52) AS claim,
       (e.embedding <=> pg_temp.synth_vec(p.probe_text, 1024)) AS cos_dist
FROM emb_bge_m3_1024 e
JOIN claims c ON c.id = e.claim_id
CROSS JOIN qd_probe p
WHERE e.user_id = :'ALICE'          -- PER-USER SCOPING (hub is per-user)
  AND e.target_kind = 'claim'
ORDER BY e.embedding <=> pg_temp.synth_vec(p.probe_text, 1024), c.id
LIMIT 5;

SELECT * FROM qd_near;

INSERT INTO q03_asserts (check_name, ok) VALUES
  ('d: exact leg sees NOTHING for the near-dup probe', (SELECT count(*) = 0 FROM qd_exact)),
  ('d: near leg returns candidates',                   (SELECT count(*) >= 3 FROM qd_near)),
  ('d: top-1 is the designated near-dup family',       (SELECT cos_dist < 0.4 FROM qd_near
                                                        ORDER BY cos_dist, claim_id LIMIT 1)),
  ('d: BOTH family members in top-2',                  (SELECT count(*) = 2 FROM qd_near
                                                        WHERE cos_dist < 0.6)),
  ('d: sharp gap to non-family claims',                (SELECT (SELECT max(cos_dist) FROM qd_near
                                                                  WHERE cos_dist < 0.6)
                                                              < (SELECT min(cos_dist) FROM qd_near
                                                                  WHERE cos_dist >= 0.6)));

\echo '=== (d) the SEAM: candidates mapped onto v_canonical_claims entries ==='
-- What the creating tool RETURNS (R-054/R-036): candidate rows carrying the
-- hub entry identity (user, canonical_text, terminal_type) so near-dups are
-- adjudicated against the same view the exact leg reads. match_kind is the
-- DR-16 growth slot's vocabulary.
CREATE TEMP TABLE qd_candidates AS
SELECT v.canonical_text, v.terminal_type, v.quest_count, v.member_claim_ids,
       'near_dup'::text AS match_kind, n.cos_dist
FROM qd_near n
JOIN claims c ON c.id = n.claim_id
JOIN v_canonical_claims v
  ON v.user_id = c.user_id AND v.canonical_text = c.canonical_text
 AND v.terminal_type IS NOT DISTINCT FROM c.terminal_type
WHERE n.cos_dist < 0.6
UNION ALL
SELECT v.canonical_text, v.terminal_type, v.quest_count, v.member_claim_ids,
       'exact'::text AS match_kind, 0.0 AS cos_dist
FROM v_canonical_claims v
WHERE v.user_id = :'ALICE'
  AND v.canonical_text = (SELECT btrim(regexp_replace(normalize(probe_text, NFC),
                                                      '[ \t\n\r\f\v]+', ' ', 'g'),
                                       ' ' || chr(9) || chr(10) || chr(13) || chr(11) || chr(12))
                          FROM qd_probe);

-- the exact-leg demo on the beta-control text: THREE quests hold it (k4
-- unterminated in A, k11 grafted to B, d1 typed in D) — grouped by the hub
-- into TWO coexisting entries (unterminated + primary-empirical), exactly
-- the DR-16 identity law, now visible on the dedup surface
CREATE TEMP TABLE qd_exact_demo AS
SELECT v.canonical_text, v.terminal_type, v.quest_count, array_length(v.member_claim_ids, 1) AS members
FROM v_canonical_claims v
WHERE v.user_id = :'ALICE'
  AND v.canonical_text = 'Momentum profits persist after controlling for market beta in the fixture literature.';

SELECT * FROM qd_candidates ORDER BY match_kind, cos_dist;
SELECT * FROM qd_exact_demo ORDER BY terminal_type NULLS FIRST;

INSERT INTO q03_asserts (check_name, ok) VALUES
  ('d: seam maps near-dup candidates onto hub entries', (SELECT count(*) >= 2 FROM qd_candidates
                                                          WHERE match_kind = 'near_dup')),
  ('d: exact demo = 2 coexisting hub entries over 3 quests', (
                   (SELECT count(*) = 2 FROM qd_exact_demo)
               AND (SELECT count(*) = 1 FROM qd_exact_demo WHERE quest_count = 2))),
  ('d: exact demo covers all 3 holding quests',          (SELECT (SELECT sum(quest_count) FROM qd_exact_demo) = 3));

\echo '=== (d4) dedup scoping: the probe AS BOB / bob AS BOB ==='
-- alice's near-dup probe scoped as bob: NOTHING (her claim family is
-- invisible across tenants). bob's own probe finds HIS claim (tenant B).
CREATE TEMP TABLE qd_cross AS
SELECT c.id AS claim_id
FROM emb_bge_m3_1024 e
JOIN claims c ON c.id = e.claim_id
CROSS JOIN qd_probe p
WHERE e.user_id = :'BOB' AND e.target_kind = 'claim'
  AND e.embedding <=> pg_temp.synth_vec(p.probe_text, 1024) < 0.6;

CREATE TEMP TABLE qd_bob AS
SELECT c.id AS claim_id, c.quest_id, left(c.canonical_text, 46) AS claim,
       (e.embedding <=> pg_temp.synth_vec(
          'cross-sectional momentum beside value and quality factor taxonomy', 1024)) AS cos_dist
FROM emb_bge_m3_1024 e
JOIN claims c ON c.id = e.claim_id
WHERE e.user_id = :'BOB' AND e.target_kind = 'claim'
ORDER BY e.embedding <=> pg_temp.synth_vec(
           'cross-sectional momentum beside value and quality factor taxonomy', 1024)
LIMIT 3;

SELECT count(*) AS alice_probe_as_bob FROM qd_cross;
SELECT * FROM qd_bob;

INSERT INTO q03_asserts (check_name, ok) VALUES
  ('d4: cross-user dedup probe returns NOTHING',  (SELECT count(*) = 0 FROM qd_cross)),
  ('d4: bob-scoped dedup finds bob own claim',    (SELECT count(*) >= 1 FROM qd_bob));

-- ============================================================================
-- (e) MECHANICAL RELEVANCE — need-text vs topic questions (R-037, I20:
--     "embed each need-text against the topic questions; cosine gives a
--     consistent relevance with zero self-assignment"). The question set is
--     the decompose output; the carrier shape (phases.result jsonb) is
--     ENTRY 6's phase contract (DR-14) — the fixture questions here mirror
--     the staged agenda note (source s5), which is where the operator's
--     questions live in the fixture corpus. Score = best question alignment
--     per open need (min cosine distance); a CONSTANT scale with NO
--     self-assignment — currency-grade for the stop law, replacing the
--     agent's own relevance field as the mass input (I20).
-- ============================================================================
\echo '=== (e) mechanical relevance: open needs x topic questions ==='
CREATE TEMP TABLE qe_questions (q_no int, question text);
INSERT INTO qe_questions VALUES
  (1, 'Which markets show the strongest cross-sectional momentum, and how large is the spread net of costs?'),
  (2, 'How do momentum crash dynamics interact with volatility regimes?');

CREATE TEMP TABLE qe_matrix AS
SELECT f.id AS need_id, left(f.need, 46) AS need, q.q_no,
       (pg_temp.synth_vec(f.need, 1024) <=> pg_temp.synth_vec(q.question, 1024)) AS cos_dist
FROM frontier_entries f
CROSS JOIN qe_questions q
WHERE f.user_id = :'ALICE'          -- PER-USER SCOPING (every leg)
  AND f.state = 'open';

CREATE TEMP TABLE qe_scores AS
SELECT need_id, need, min(cos_dist) AS best_cos_dist,
       (array_agg(q_no ORDER BY cos_dist, q_no))[1] AS best_question
FROM qe_matrix
GROUP BY need_id, need;

SELECT m.need, m.q_no, round(m.cos_dist::numeric, 4) AS cos_dist FROM qe_matrix m ORDER BY m.need, m.q_no;
SELECT * FROM qe_scores ORDER BY best_cos_dist;

INSERT INTO q03_asserts (check_name, ok) VALUES
  ('e: every OPEN need scored (all 3 present)',  (SELECT count(*) = (
                                                   SELECT count(*) FROM frontier_entries
                                                   WHERE user_id = :'ALICE' AND state = 'open')
                                                 FROM qe_scores)),
  ('e: crash need aligns with the CRASH question', (SELECT best_question = 2 FROM qe_scores
                                                     WHERE need LIKE 'primary empirical evidence on momentum crash%')),
  ('e: cross-market need aligns with the MAGNITUDE question', (SELECT best_question = 1 FROM qe_scores
                                                     WHERE need LIKE 'cross-market estimates%')),
  ('e: scores are not constant (usable currency)', (SELECT count(DISTINCT round(best_cos_dist::numeric, 4)) >= 2
                                                    FROM qe_scores)),
  ('e: scores recompute from text alone (zero self-assignment)', (
                 SELECT count(*) = 0 FROM qe_scores s
                 JOIN frontier_entries f ON f.id = s.need_id
                 WHERE s.best_cos_dist <> (pg_temp.synth_vec(f.need, 1024) <=>
                     pg_temp.synth_vec((SELECT question FROM qe_questions WHERE q_no = s.best_question), 1024))));

-- ============================================================================
-- assertions gate — any false row aborts the run
-- ============================================================================
SELECT check_name, ok FROM q03_asserts ORDER BY check_name;
ALTER TABLE q03_asserts ADD CONSTRAINT ck_q03_asserts_all_ok CHECK (ok);
DROP TABLE q03_asserts;
