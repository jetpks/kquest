-- ============================================================================
-- kquest I02 cross-quest — seed fixtures (seed-i02.sql)
-- ----------------------------------------------------------------------------
-- Loads AFTER design/I01-core-model/artifacts/{schema,seed}.sql. All fixture
-- bodies are SYNTHETIC. New paths exercised (Specification, output format):
--   - canonical hub: 3 canonical claims, minted via the DR-03 algorithm;
--   - merge lifecycle: candidate / proposed / approved x2 / rejected(near_dup)
--     / approved-then-REVERSED (the reversibility fixture);
--   - lineage: continuation quest D (graph_graft of quest A) with grafted
--     claims (origin_quest_id stamps), grafted frontier DRAINED to zero, and
--     corpus inheritance as an AT-INIT COPY (A stages s7 AFTER D spawned);
--   - lifecycle: quest D complete -> archived via the ledger, with a
--     completed verification phase and pinned archive counts;
--   - reports: 2 versions on quest D (re-synthesis with a different model),
--     standing pointer on v2, v1 stale+unbound, binding pass on v2
--     (ordinals 2,3 in-corpus + ordinal 5 explicit import from quest A);
--   - visibility: workspace kquest-lab {alice,carol}; grants public x2,
--     user x1, workspace x2; private-by-absence fixtures.
-- Self-verification at the end re-derives: cclaim URNs, exact-merge text
-- equality, the citation binding pass (deterministic re-bind from the body +
-- citation index + import manifest), the footnote block, archive counts vs
-- live counts, and the visibility expectations. plpgsql-free (I01 pattern).
-- ============================================================================

BEGIN;

-- base58 (Bitcoin alphabet), pure SQL — identical to the I01 seed helper
CREATE FUNCTION pg_temp.kb_base58(data bytea) RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
WITH RECURSIVE num AS (
  SELECT sum(get_byte(data, i)::numeric * power(256::numeric, octet_length(data) - 1 - i)) AS n
  FROM generate_series(0, octet_length(data) - 1) AS i
), digits AS (
  SELECT n, 0 AS depth FROM num
  UNION ALL
  SELECT div(digits.n, 58), digits.depth + 1 FROM digits WHERE digits.n > 0
), zeros AS (
  SELECT repeat('1', coalesce((
    SELECT min(i) FROM generate_series(0, octet_length(data) - 1) AS i
    WHERE get_byte(data, i) <> 0), octet_length(data))) AS z
)
SELECT (SELECT z FROM zeros)
  || coalesce((SELECT string_agg(
       substr('123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz',
              (d.n % 58)::integer + 1, 1), '' ORDER BY d.depth DESC)
     FROM digits d WHERE d.n > 0), '')
$fn$;

CREATE TEMP TABLE seed_asserts (
  check_name text PRIMARY KEY,
  violations integer NOT NULL
);

-- ---------------------------------------------------------------------------
-- fixture bodies needed by this seed (evidence offsets for quest D, the
-- s7 source body, and the two report bodies; s2/s3/s4 bodies are identical
-- to the I01 seed's)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE fixture_bodies (
  tag  text PRIMARY KEY,
  body text NOT NULL
);
INSERT INTO fixture_bodies (tag, body) VALUES
('s2', $fx$In the fixture window of 1963 to 1990 cross-sectional winners outperformed losers by about one percent per month in the fixture literature.
The fixture primer reports a WML spread that remains positive after controlling for market beta.
Momentum spreads survive beta controls in the fixture regression table with t-statistics above three.
Reversal at the one-month horizon partially offsets the gross spread in the fixture sample.
Fixture text synthesized for the kquest I01 seed; it quotes no real source.$fx$),
('s3', $fx$Round-trip transaction costs consume roughly 40 basis points of the gross momentum spread in the fixture market model.
Net-of-cost momentum is modest but positive once the fixture cost assumption is applied.
The fixture cost model charges eight basis points per side plus a spread crossing fee.
Fixture text synthesized for the kquest I01 seed; it quotes no real source.$fx$),
('s4', $fx$Momentum strategy drawdowns cluster in market rebound regimes in the fixture risk documentation.
The fixture risk model attributes the 2009-style crash to a sharp factor rotation.
Volatility scaling reduces but does not eliminate the fixture drawdown profile.
Fixture text synthesized for the kquest I01 seed; it quotes no real source.$fx$),
('s7', $fx$Fixture regulators require cost disclosure in net-return reporting.
Fixture text synthesized for the kquest I02 seed; it quotes no real source.$fx$),
('rv1', $fx$Superseded first synthesis of the continuation quest (fixture): one paragraph, written by glm-5.3 and later re-synthesized on the same graph by a different model. No citations were bound before supersession.$fx$),
('rv2', $fx$The continuation graft re-anchored the beta-control span from the inherited primer [^2] and confirmed modest net-of-cost persistence under the fixture cost assumption [^3]. The parent quest later staged the fixture regulation note [^5], imported here and explicitly marked. Crash clustering remains flagged residual at the per-stock level.$fx$);

-- fixed ids used below AND by queries-i02.sql / check-constraints.sh
--   ALICE/BOB/QA/QB/QC : the I01 seed's fixed ids
--   CAROL  00000000-...-03   new tenant (workspace member)
--   QD     b0000000-...-10   continuation quest (graph_graft of QA)
--   S7     a0000000-...-07   alice's late citable fetch (staged into QA only)
--   K4/K5/K6/K11           I01 claims (merge fixtures target these)
--   D1..D3 f0000000-...-101/102/103   quest D claims (d1,d2 grafted)
--   PD11..PD16 d0000000-...-011..016 quest D phases
--   SD11..SD16 e0000000-...-011..016 quest D sessions
--   CC1..CC3 80000000-...-01/02/03   canonical claims
--   E1..E6  90000000-...-01..06      merge events
--   RV1/RV2 aa000000-...-b1/b2       report versions
--   RC2/RC3/RC5 ab000000-...-c2/c3/c5 report citations
--   LE1/LE2 bb000000-...-e1/e2       lifecycle events
--   WS1     cc000000-...-01          workspace kquest-lab
--   G1..G5  dd000000-...-01..05      resource grants

-- ---------------------------------------------------------------------------
-- new tenant + late source (s7) — staged into quest A ONLY, after quest D
-- was initialized: inheritance is an at-init copy, never a live sync (DR-18)
-- ---------------------------------------------------------------------------
INSERT INTO users (id, handle, display_name) VALUES
('00000000-0000-4000-8000-000000000003', 'carol', 'Carol Fixture');

INSERT INTO sources
  (id, user_id, url, canonical_url, urn, title, role, published_at, fetched_at,
   snapshot_sha256, raw_sha256, snapshot_char_count)
SELECT 'a0000000-0000-4000-8000-000000000007', '00000000-0000-4000-8000-000000000001',
       'https://fixture.example/regulation-note', 'https://fixture.example/regulation-note',
       'kb:src:' || substr(pg_temp.kb_base58(
         sha256(convert_to('https://fixture.example/regulation-note' || m.snap_sha, 'UTF8'))), 1, 10),
       'Fixture net-cost regulation note (synthetic)', 'citable', NULL, '2026-11-22T12:00:00+00',
       m.snap_sha,
       encode(sha256(convert_to('raw-envelope:s7:' || m.body, 'UTF8')), 'hex'),
       m.chars
FROM (SELECT body, encode(sha256(convert_to(body, 'UTF8')), 'hex') AS snap_sha,
             char_length(body) AS chars
      FROM fixture_bodies WHERE tag = 's7') m;

INSERT INTO quest_sources (quest_id, source_id, user_id, added_at) VALUES
('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000007',
 '00000000-0000-4000-8000-000000000001', '2026-11-22T16:00:00+00');

-- ---------------------------------------------------------------------------
-- quest D — the drained continuation (graph_graft of quest A; v4 precedent)
-- ---------------------------------------------------------------------------
INSERT INTO quests
  (id, user_id, topic, state, provenance_kind, source_quest_id,
   web_call_budget, token_budget, spend_budget_usd, model_config, process_config) VALUES
('b0000000-0000-4000-8000-000000000010', '00000000-0000-4000-8000-000000000001',
 'Momentum continuation: drain the inherited crash frontier (fixture)', 'complete', 'graph_graft',
 'b0000000-0000-4000-8000-000000000001',
 300, 10000000, 8.0000,
 '{"decompose":"glm-5.3","descent":"glm-5.3","synthesis":"openai/gpt-6.2-astra","verification":"glm-5.3"}'::jsonb,
 '{}'::jsonb);

-- corpus inheritance: AT-INIT copy of quest A's corpus (s1..s5, incl. the
-- agenda note — readable, never anchorable); s7 is deliberately absent.
-- added_at staggered => deterministic citation index s1,s2,s3,s4 (citable)
INSERT INTO quest_sources (quest_id, source_id, user_id, added_at) VALUES
('b0000000-0000-4000-8000-000000000010', 'a0000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001', '2026-11-22T12:30:00+00'),
('b0000000-0000-4000-8000-000000000010', 'a0000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001', '2026-11-22T12:31:00+00'),
('b0000000-0000-4000-8000-000000000010', 'a0000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000001', '2026-11-22T12:32:00+00'),
('b0000000-0000-4000-8000-000000000010', 'a0000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000001', '2026-11-22T12:33:00+00'),
('b0000000-0000-4000-8000-000000000010', 'a0000000-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000001', '2026-11-22T12:34:00+00');

-- quest D phases: decompose (graft) -> descent (drain) -> synthesis r1 ->
-- verification r1 -> synthesis r2 (RE-SYNTHESIS) -> verification r2
INSERT INTO phases
  (id, user_id, quest_id, kind, round_no, attempt_no, state,
   started_at, ended_at, wall_timeout_s, result, frontier_open, frontier_mass) VALUES
('d0000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'decompose', 1, 1, 'complete',
 '2026-11-22T12:35:00+00', '2026-11-22T12:50:00+00', 2700,
 '{"summary":"fixture continuation init: grafted k4/k6 as d1/d2 with one open frontier entry (u5xr4=20); corpus copied at init"}'::jsonb, 1, 20),
('d0000000-0000-4000-8000-000000000012', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'descent', 1, 1, 'complete',
 '2026-11-22T12:51:00+00', '2026-11-22T13:20:00+00', 2700,
 '{"summary":"drained continuation: crash need closed internal; +3 evidence; frontier 1 -> 0 (mass 20 -> 0)"}'::jsonb, 0, 0),
('d0000000-0000-4000-8000-000000000013', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'synthesis', 1, 1, 'complete',
 '2026-11-22T13:21:00+00', '2026-11-22T13:40:00+00', 3600,
 '{"summary":"fixture synthesis v1 (glm-5.3)"}'::jsonb, 0, 0),
('d0000000-0000-4000-8000-000000000014', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'verification', 1, 1, 'complete',
 '2026-11-22T13:41:00+00', '2026-11-22T13:55:00+00', 2700,
 '{"summary":"paths clean; spot checks pass"}'::jsonb, 0, 0),
('d0000000-0000-4000-8000-000000000015', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'synthesis', 2, 1, 'complete',
 '2026-11-22T14:10:00+00', '2026-11-22T14:35:00+00', 3600,
 '{"summary":"fixture re-synthesis v2 (astra) on the SAME graph", "citation_index":"quest_sources citable by (added_at, source_id)"}'::jsonb, 0, 0),
('d0000000-0000-4000-8000-000000000016', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'verification', 2, 1, 'complete',
 '2026-11-22T14:36:00+00', '2026-11-22T14:45:00+00', 2700,
 '{"summary":"re-verification of v2: paths clean, citations bound"}'::jsonb, 0, 0);

-- the re-synthesis phase carries the IMPORT MANIFEST (R-027): ordinal 5 is
-- beyond the corpus citation index (4 citable sources) and resolves to s7,
-- staged in quest A AFTER quest D inherited the corpus
UPDATE phases
SET result = jsonb_set(result, '{imports}',
  ('[{"ordinal":5,"source_urn":"' || s.urn
   || '","from_quest":"b0000000-0000-4000-8000-000000000001"}]')::jsonb)
FROM sources s
WHERE phases.id = 'd0000000-0000-4000-8000-000000000015'
  AND s.id = 'a0000000-0000-4000-8000-000000000007';

-- six sessions, one per phase attempt (decompose/descent/syn1/verif1/syn2/
-- verif2); the re-synthesis session records the model swap (R-061 economics)
INSERT INTO sessions
  (id, user_id, quest_id, phase_id, mode, driver, model, transcript_blob_key,
   started_at, ended_at) VALUES
('e0000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'd0000000-0000-4000-8000-000000000011',
 'autonomous', 'orchestrator', 'glm-5.3',
 'sessions/e0000000-0000-4000-8000-000000000011/transcript.jsonl',
 '2026-11-22T12:35:00+00', '2026-11-22T12:50:00+00'),
('e0000000-0000-4000-8000-000000000012', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'd0000000-0000-4000-8000-000000000012',
 'autonomous', 'orchestrator', 'glm-5.3',
 'sessions/e0000000-0000-4000-8000-000000000012/transcript.jsonl',
 '2026-11-22T12:51:00+00', '2026-11-22T13:20:00+00'),
('e0000000-0000-4000-8000-000000000013', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'd0000000-0000-4000-8000-000000000013',
 'autonomous', 'orchestrator', 'glm-5.3',
 'sessions/e0000000-0000-4000-8000-000000000013/transcript.jsonl',
 '2026-11-22T13:21:00+00', '2026-11-22T13:40:00+00'),
('e0000000-0000-4000-8000-000000000014', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'd0000000-0000-4000-8000-000000000014',
 'autonomous', 'orchestrator', 'glm-5.3',
 'sessions/e0000000-0000-4000-8000-000000000014/transcript.jsonl',
 '2026-11-22T13:41:00+00', '2026-11-22T13:55:00+00'),
('e0000000-0000-4000-8000-000000000015', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'd0000000-0000-4000-8000-000000000015',
 'autonomous', 'orchestrator', 'openai/gpt-6.2-astra',
 'sessions/e0000000-0000-4000-8000-000000000015/transcript.jsonl',
 '2026-11-22T14:10:00+00', '2026-11-22T14:35:00+00'),
('e0000000-0000-4000-8000-000000000016', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'd0000000-0000-4000-8000-000000000016',
 'autonomous', 'orchestrator', 'glm-5.3',
 'sessions/e0000000-0000-4000-8000-000000000016/transcript.jsonl',
 '2026-11-22T14:36:00+00', '2026-11-22T14:45:00+00');

-- ---------------------------------------------------------------------------
-- quest D claims: d1/d2 grafted from quest A (origin stamps), d3 fresh.
-- URNs minted per I01 DR-06 (quest-salted — graft does NOT re-address).
-- ---------------------------------------------------------------------------
INSERT INTO claims
  (id, user_id, quest_id, quest_seq, text, terminal_type, terminal_basis, urn,
   origin_quest_id, created_session_id)
SELECT c.id, c.user_id, c.quest_id, c.quest_seq, c.text, c.terminal_type, c.terminal_basis,
       'kb:claim:' || substr(pg_temp.kb_base58(
         sha256(convert_to(c.quest_id::text || norm.canonical_text, 'UTF8'))), 1, 10),
       c.origin_quest_id, c.created_session_id
FROM (VALUES
-- d1: graft of quest A's k4 (beta-control persistence); terminal reached in
--     the continuation via re-anchored evidence
('f0000000-0000-4000-8000-000000000101'::uuid, '00000000-0000-4000-8000-000000000001'::uuid,
 'b0000000-0000-4000-8000-000000000010'::uuid, 1,
 'Momentum profits persist after controlling for market beta in the fixture literature.',
 'primary-empirical'::text, 'Beta-control regression re-anchored from the inherited primer in the continuation.'::text,
 'b0000000-0000-4000-8000-000000000001'::uuid, 'e0000000-0000-4000-8000-000000000011'::uuid),
-- d2: graft of quest A's k6 (crash idiosyncrasy); resolved as residual in the
--     continuation; its grafted frontier entry is closed 'internal' (drain)
('f0000000-0000-4000-8000-000000000102'::uuid, '00000000-0000-4000-8000-000000000001'::uuid,
 'b0000000-0000-4000-8000-000000000010'::uuid, 2,
 'Momentum crash dynamics are idiosyncratic to individual stocks.',
 'residual-uncertainty'::text, 'No fixture source resolves per-stock versus strategy-level clustering; flagged residual at drain.'::text,
 'b0000000-0000-4000-8000-000000000001'::uuid, 'e0000000-0000-4000-8000-000000000011'::uuid),
-- d3: quest D's own conclusion (near-dup of quest A's k5 — rejected-merge
--     fixture; then approved as the first member of its own canonical claim)
('f0000000-0000-4000-8000-000000000103'::uuid, '00000000-0000-4000-8000-000000000001'::uuid,
 'b0000000-0000-4000-8000-000000000010'::uuid, 3,
 'Net-of-cost momentum is modest but positive under the fixture cost assumption.',
 'primary-empirical'::text, 'Net-of-cost line of the fixture costs note, re-anchored in the continuation.'::text,
 NULL::uuid, 'e0000000-0000-4000-8000-000000000012'::uuid)
) AS c(id, user_id, quest_id, quest_seq, text, terminal_type, terminal_basis,
       origin_quest_id, created_session_id),
LATERAL (SELECT btrim(regexp_replace(normalize(c.text, NFC), '[ \t\n\r\f\v]+', ' ', 'g'),
                      ' ' || chr(9) || chr(10) || chr(13) || chr(11) || chr(12)) AS canonical_text) norm;

-- ---------------------------------------------------------------------------
-- quest D evidence: spans re-derived from the fixture bodies (position());
-- uq_evidence_quest_span is PER QUEST, so re-anchoring the same span of the
-- same source in a new quest is legal (graft semantics)
-- ---------------------------------------------------------------------------
INSERT INTO seed_asserts (check_name, violations)
SELECT 'i02_evidence_spans_present', count(*)
FROM (VALUES
  ('s2', $sp$Momentum spreads survive beta controls in the fixture regression table$sp$),
  ('s4', $sp$Momentum strategy drawdowns cluster in market rebound regimes$sp$),
  ('s3', $sp$Net-of-cost momentum is modest but positive once the fixture cost assumption is applied.$sp$)
) AS e(source_tag, span_literal)
JOIN fixture_bodies fb ON fb.tag = e.source_tag
WHERE position(e.span_literal IN fb.body) = 0;
ALTER TABLE seed_asserts ADD CONSTRAINT ck_seed_i02_spans CHECK (violations = 0);

INSERT INTO evidence
  (id, user_id, quest_id, source_id, source_anchorable, snapshot_char_count,
   span_start, span_end, span_text, reading, created_session_id)
SELECT e.id, fs.user_id, e.quest_id, fs.id, true, char_length(fb.body),
       position(e.span_literal IN fb.body) - 1,
       position(e.span_literal IN fb.body) - 1 + char_length(e.span_literal),
       e.span_literal, e.reading, e.created_session_id
FROM (VALUES
  ('10000000-0000-4000-8000-000000000101'::uuid, 's2', 'b0000000-0000-4000-8000-000000000010'::uuid,
   $sp$Momentum spreads survive beta controls in the fixture regression table$sp$,
   'beta-control persistence re-anchored in the continuation',
   'e0000000-0000-4000-8000-000000000012'::uuid),
  ('10000000-0000-4000-8000-000000000102'::uuid, 's4', 'b0000000-0000-4000-8000-000000000010'::uuid,
   $sp$Momentum strategy drawdowns cluster in market rebound regimes$sp$,
   'strategy-level clustering contradicts per-stock idiosyncrasy',
   'e0000000-0000-4000-8000-000000000012'::uuid),
  ('10000000-0000-4000-8000-000000000103'::uuid, 's3', 'b0000000-0000-4000-8000-000000000010'::uuid,
   $sp$Net-of-cost momentum is modest but positive once the fixture cost assumption is applied.$sp$,
   'net-of-cost line re-anchored for the continuation conclusion',
   'e0000000-0000-4000-8000-000000000012'::uuid)
) AS e(id, source_tag, quest_id, span_literal, reading, created_session_id)
JOIN (SELECT 's2'::text AS tag, user_id, id FROM sources WHERE id = 'a0000000-0000-4000-8000-000000000002'
      UNION ALL SELECT 's3', user_id, id FROM sources WHERE id = 'a0000000-0000-4000-8000-000000000003'
      UNION ALL SELECT 's4', user_id, id FROM sources WHERE id = 'a0000000-0000-4000-8000-000000000004') fs
  ON fs.tag = e.source_tag
JOIN fixture_bodies fb ON fb.tag = e.source_tag;

INSERT INTO evidence_edges
  (id, user_id, quest_id, evidence_id, relation, claim_id, position) VALUES
('20000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', '10000000-0000-4000-8000-000000000101',
 'supports', 'f0000000-0000-4000-8000-000000000101', 1),
('20000000-0000-4000-8000-000000000102', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', '10000000-0000-4000-8000-000000000102',
 'contradicts', 'f0000000-0000-4000-8000-000000000102', 1),
('20000000-0000-4000-8000-000000000103', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', '10000000-0000-4000-8000-000000000103',
 'supports', 'f0000000-0000-4000-8000-000000000103', 1);

-- grafted frontier entry, then DRAINED (closed internal) — the drained-exit
-- continuation; scores inherited from the source quest's entry (u5 x r4 = 20)
INSERT INTO frontier_entries
  (id, user_id, quest_id, claim_id, need, uncertainty, relevance, state,
   spawned_by_phase_id, opened_at, closed_at, closure_type) VALUES
('40000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'f0000000-0000-4000-8000-000000000102',
 'per-stock versus strategy-level momentum crash clustering evidence',
 5, 4, 'closed', 'd0000000-0000-4000-8000-000000000011',
 '2026-11-22T12:40:00+00', '2026-11-22T13:15:00+00', 'internal');

-- usage ledger continuity for the two synthesis sessions (D10)
INSERT INTO usage_events
  (id, user_id, quest_id, phase_id, session_id, kind, model,
   input_tokens, output_tokens, cost_usd, created_at) VALUES
('70000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'd0000000-0000-4000-8000-000000000013',
 'e0000000-0000-4000-8000-000000000013', 'llm', 'glm-5.3', 64200, 4100, 0.033900, '2026-11-22T13:22:00+00'),
('70000000-0000-4000-8000-000000000012', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'd0000000-0000-4000-8000-000000000015',
 'e0000000-0000-4000-8000-000000000015', 'llm', 'openai/gpt-6.2-astra', 121000, 5600, 1.204000, '2026-11-22T14:11:00+00');

-- ---------------------------------------------------------------------------
-- canonical hub (R-019) — URNs minted per DR-03: kb:cclaim:base58(
-- sha256(canonical_text))[0:10]; canonical_text taken FROM the member claims
-- (byte-equal to their generated canonical_text by construction)
-- ---------------------------------------------------------------------------
INSERT INTO canonical_claims (id, user_id, canonical_text, urn, terminal_type, terminal_basis, created_at)
SELECT cc.id, cc.user_id, c.canonical_text,
       'kb:cclaim:' || substr(pg_temp.kb_base58(sha256(convert_to(c.canonical_text, 'UTF8'))), 1, 10),
       cc.terminal_type, cc.terminal_basis, cc.created_at
FROM (VALUES
-- CC1: the beta-control persistence line (k4 / k11 / d1 all hold this text)
('80000000-0000-4000-8000-000000000001'::uuid, '00000000-0000-4000-8000-000000000001'::uuid,
 'f0000000-0000-4000-8000-000000000004'::uuid, NULL::text, NULL::text, '2026-11-22T15:15:00+00'::timestamptz),
-- CC2: the net-of-cost market-model line (k5) — membership reversed (E4)
('80000000-0000-4000-8000-000000000002'::uuid, '00000000-0000-4000-8000-000000000001'::uuid,
 'f0000000-0000-4000-8000-000000000005'::uuid, NULL::text, NULL::text, '2026-11-22T15:18:00+00'::timestamptz),
-- CC3: the continuation's net-of-cost conclusion (d3) — terminal adopted at
--     first approval (E6)
('80000000-0000-4000-8000-000000000003'::uuid, '00000000-0000-4000-8000-000000000001'::uuid,
 'f0000000-0000-4000-8000-000000000103'::uuid, NULL::text, NULL::text, '2026-11-22T15:39:00+00'::timestamptz)
) AS cc(id, user_id, claim_id, terminal_type, terminal_basis, created_at)
JOIN claims c ON c.id = cc.claim_id;

-- terminal adoption for CC3 at approval time (adopt-first-member, DR-06)
UPDATE canonical_claims cc
SET terminal_type = c.terminal_type, terminal_basis = c.terminal_basis
FROM claims c
WHERE cc.id = '80000000-0000-4000-8000-000000000003'
  AND c.id = 'f0000000-0000-4000-8000-000000000103';

-- ---------------------------------------------------------------------------
-- merge events (R-019/R-020): candidate / proposed / approved / rejected /
-- approved-then-reversed; exact leg live, near-dup leg as the designated slot
-- ---------------------------------------------------------------------------
INSERT INTO merge_events
  (id, user_id, canonical_claim_id, quest_id, quest_claim_id, match_kind,
   similarity, state, justification, proposed_session_id,
   decided_by, decided_at, decision_note,
   reversed_by, reversed_at, reversal_note, created_at) VALUES
-- E1: k4 -> CC1, approved (the canonical member)
('90000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001',
 '80000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001',
 'f0000000-0000-4000-8000-000000000004', 'exact', NULL, 'approved',
 'exact canonical-text match: quest-A original of the grafted line',
 'e0000000-0000-4000-8000-000000000001',
 '00000000-0000-4000-8000-000000000001', '2026-11-22T15:20:00+00',
 'original phrasing wins as the hub text', NULL, NULL, NULL, '2026-11-22T15:16:00+00'),
-- E2: k11 -> CC1, proposed (awaiting operator decision)
('90000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001',
 '80000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002',
 'f0000000-0000-4000-8000-000000000011', 'exact', NULL, 'proposed',
 'quest-B graft of the same canonical text; presented for approval', NULL,
 NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-22T15:17:00+00'),
-- E3: d1 -> CC1, candidate (generated, not yet presented)
('90000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000001',
 '80000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000010',
 'f0000000-0000-4000-8000-000000000101', 'exact', NULL, 'candidate',
 'continuation graft of k4: same canonical text by construction',
 'e0000000-0000-4000-8000-000000000011',
 NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-22T15:21:00+00'),
-- E4: k5 -> CC2, approved then REVERSED (the reversibility fixture)
('90000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000001',
 '80000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000001',
 'f0000000-0000-4000-8000-000000000005', 'exact', NULL, 'reversed',
 'exact canonical-text match against CC2',
 'e0000000-0000-4000-8000-000000000001',
 '00000000-0000-4000-8000-000000000001', '2026-11-22T15:22:00+00',
 'approved on exact match',
 '00000000-0000-4000-8000-000000000001', '2026-11-22T15:35:00+00',
 'post-merge terminal-basis divergence discovered: member claims disagree on scoping; membership withdrawn pending the ENTRY 3 near-dup policy',
 '2026-11-22T15:19:00+00'),
-- E5: d3 -> CC2, near_dup, REJECTED (the designated-slot fixture: score is
--     fixture data until ENTRY 3 wires embeddings)
('90000000-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000001',
 '80000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000010',
 'f0000000-0000-4000-8000-000000000103', 'near_dup', 0.8340, 'rejected',
 'near-duplicate of the net-of-cost market-model line (embedding score fixture)',
 'e0000000-0000-4000-8000-000000000012',
 '00000000-0000-4000-8000-000000000001', '2026-11-22T15:30:00+00',
 'distinct claims: market-model scope vs cost-assumption scope; similarity below the adopt threshold', NULL, NULL, NULL,
 '2026-11-22T15:23:00+00'),
-- E6: d3 -> CC3, approved (rejected E5 is inactive; a new lifecycle is legal)
('90000000-0000-4000-8000-000000000006', '00000000-0000-4000-8000-000000000001',
 '80000000-0000-4000-8000-000000000003', 'b0000000-0000-4000-8000-000000000010',
 'f0000000-0000-4000-8000-000000000103', 'exact', NULL, 'approved',
 'continuation re-anchored the net-of-cost line with its own evidence; first-class member of its own canonical claim',
 'e0000000-0000-4000-8000-000000000012',
 '00000000-0000-4000-8000-000000000001', '2026-11-22T15:40:00+00',
 'terminal adopted from first member', NULL, NULL, NULL, '2026-11-22T15:39:00+00');

-- ---------------------------------------------------------------------------
-- lifecycle (R-022): quest D active -> complete (orchestrator, verification
-- r2 passed) -> archived (operator), archive gates + counts pinned at freeze
-- ---------------------------------------------------------------------------
INSERT INTO quest_lifecycle_events
  (id, user_id, quest_id, from_state, to_state, actor, occurred_at, note) VALUES
('bb000000-0000-4000-8000-0000000000e1', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'active', 'complete', 'orchestrator',
 '2026-11-22T14:46:00+00', 'verification round 2 complete; never-reportless finisher honored');

INSERT INTO quest_lifecycle_events
  (id, user_id, quest_id, from_state, to_state, actor,
   verification_phase_id, claims_at_archive, evidence_at_archive, frontier_open_at_archive,
   occurred_at, note) VALUES
('bb000000-0000-4000-8000-0000000000e2', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'complete', 'archived', 'operator',
 'd0000000-0000-4000-8000-000000000016', 3, 3, 0,
 '2026-11-22T15:00:00+00', 'archive after verified re-synthesis; graph frozen');

UPDATE quests SET state = 'complete' WHERE id = 'b0000000-0000-4000-8000-000000000010';
UPDATE quests SET state = 'archived' WHERE id = 'b0000000-0000-4000-8000-000000000010';

-- ---------------------------------------------------------------------------
-- report versions (R-023/R-024): v1 superseded+unbound, v2 standing+bound
-- (re-synthesis with a different model on the SAME graph)
-- ---------------------------------------------------------------------------
INSERT INTO report_versions
  (id, user_id, quest_id, version_seq, synthesis_phase_id, created_session_id,
   model, body_blob_key, body_sha256, standing, bound_at, binding_pass, created_at)
SELECT rv.id, rv.user_id, rv.quest_id, rv.version_seq, rv.phase_id, rv.session_id,
       rv.model, 'reports/' || rv.quest_id::text || '/v' || rv.version_seq || '.md',
       encode(sha256(convert_to(fb.body, 'UTF8')), 'hex'),
       rv.standing, rv.bound_at, rv.binding_pass, rv.created_at
FROM (VALUES
('aa000000-0000-4000-8000-0000000000b1'::uuid, '00000000-0000-4000-8000-000000000001'::uuid,
 'b0000000-0000-4000-8000-000000000010'::uuid, 1,
 'd0000000-0000-4000-8000-000000000013'::uuid, 'e0000000-0000-4000-8000-000000000013'::uuid,
 'glm-5.3'::text, false, NULL::timestamptz, NULL::text, '2026-11-22T13:40:00+00'::timestamptz),
('aa000000-0000-4000-8000-0000000000b2'::uuid, '00000000-0000-4000-8000-000000000001'::uuid,
 'b0000000-0000-4000-8000-000000000010'::uuid, 2,
 'd0000000-0000-4000-8000-000000000015'::uuid, 'e0000000-0000-4000-8000-000000000015'::uuid,
 'openai/gpt-6.2-astra', true, '2026-11-22T14:50:00+00'::timestamptz, 'cite-bind/1', '2026-11-22T14:36:00+00'::timestamptz)
) AS rv(id, user_id, quest_id, version_seq, phase_id, session_id, model, standing, bound_at, binding_pass, created_at)
JOIN fixture_bodies fb ON fb.tag = 'rv' || rv.version_seq::text;

-- ---------------------------------------------------------------------------
-- citation binding output (R-026/R-027): v2 ordinals {2,3} in-corpus, {5}
-- explicit import from quest A (the source quest that later staged s7)
-- ---------------------------------------------------------------------------
INSERT INTO report_citations
  (id, user_id, quest_id, report_version_id, ordinal,
   source_id, source_anchorable, imported_source_id, imported_source_anchorable,
   imported, import_source_quest_id)
VALUES
('ab000000-0000-4000-8000-0000000000c2', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'aa000000-0000-4000-8000-0000000000b2', 2,
 'a0000000-0000-4000-8000-000000000002', true, NULL, true, false, NULL),
('ab000000-0000-4000-8000-0000000000c3', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'aa000000-0000-4000-8000-0000000000b2', 3,
 'a0000000-0000-4000-8000-000000000003', true, NULL, true, false, NULL),
('ab000000-0000-4000-8000-0000000000c5', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'aa000000-0000-4000-8000-0000000000b2', 5,
 NULL, true, 'a0000000-0000-4000-8000-000000000007', true, true,
 'b0000000-0000-4000-8000-000000000001');

-- ---------------------------------------------------------------------------
-- visibility layer (R-025, D6): workspace + user/public/workspace grants;
-- private = absence of a row (s2, s7, CC2, CC3 stay private)
-- ---------------------------------------------------------------------------
INSERT INTO workspaces (id, name, created_by_user_id) VALUES
('cc000000-0000-4000-8000-000000000001', 'kquest-lab', '00000000-0000-4000-8000-000000000001');

INSERT INTO workspace_members (workspace_id, user_id) VALUES
('cc000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001'),
('cc000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000003');

INSERT INTO resource_grants
  (id, owner_user_id, source_id, canonical_claim_id, grantee_user_id,
   grantee_workspace_id, is_public, note) VALUES
-- G1: alice's s3 -> PUBLIC (the global door)
('dd000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001',
 'a0000000-0000-4000-8000-000000000003', NULL, NULL, NULL, true, 'public costs note'),
-- G2: alice's s1 -> user bob (a targeted share)
('dd000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001',
 'a0000000-0000-4000-8000-000000000001', NULL, '00000000-0000-4000-8000-000000000002', NULL, false, 'shared with bob'),
-- G3: alice's s4 -> workspace kquest-lab
('dd000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000001',
 'a0000000-0000-4000-8000-000000000004', NULL, NULL, 'cc000000-0000-4000-8000-000000000001', false, NULL),
-- G4: alice's canonical CC1 -> workspace kquest-lab (canonical claims share
--     through the SAME mechanism, D6)
('dd000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000001',
 NULL, '80000000-0000-4000-8000-000000000001', NULL, 'cc000000-0000-4000-8000-000000000001', false, NULL),
-- G5: bob's s6 -> PUBLIC (cross-tenant public read)
('dd000000-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000002',
 'a0000000-0000-4000-8000-000000000006', NULL, NULL, NULL, true, 'tenant-B factor zoo, public');

-- ============================================================================
-- SELF-VERIFICATION — any nonzero count aborts the load (assert idiom)
-- ============================================================================
-- DR-03: canonical claim URN re-derivation from the canonical text
INSERT INTO seed_asserts
SELECT 'cclaim_urn_algorithm_dr03', (
  SELECT count(*) FROM canonical_claims cc
  WHERE 'kb:cclaim:' || substr(pg_temp.kb_base58(
          sha256(convert_to(cc.canonical_text, 'UTF8'))), 1, 10) <> cc.urn);

-- exactMatch semantics: every exact event (any state) pairs byte-equal texts;
-- every near_dup event pairs texts that are NOT equal (slot fixture honesty)
INSERT INTO seed_asserts
SELECT 'merge_exact_texts_equal', (
  SELECT count(*) FROM merge_events me
  JOIN claims c ON c.id = me.quest_claim_id
  JOIN canonical_claims cc ON cc.id = me.canonical_claim_id
  WHERE (me.match_kind = 'exact' AND c.canonical_text <> cc.canonical_text)
     OR (me.match_kind = 'near_dup' AND c.canonical_text = cc.canonical_text));

-- approved events pair same-owner endpoints (tenancy law holds in fixtures)
INSERT INTO seed_asserts
SELECT 'merge_same_owner', (
  SELECT count(*) FROM merge_events me
  JOIN claims c ON c.id = me.quest_claim_id
  JOIN canonical_claims cc ON cc.id = me.canonical_claim_id
  WHERE c.user_id <> cc.user_id);

-- R-022: archived quests have a COMPLETED VERIFICATION phase (FK pins it)
-- and their live counts equal the pinned archive counts (drift = 0)
INSERT INTO seed_asserts
SELECT 'archive_drift_zero', (
  SELECT count(*) FROM quest_lifecycle_events e
  JOIN quests q ON q.id = e.quest_id
  WHERE e.to_state = 'archived'
    AND (q.state <> 'archived'
      OR e.claims_at_archive <> (SELECT count(*) FROM claims c WHERE c.quest_id = e.quest_id)
      OR e.evidence_at_archive <> (SELECT count(*) FROM evidence v WHERE v.quest_id = e.quest_id)
      OR e.frontier_open_at_archive <> (SELECT count(*) FROM frontier_entries f
                                        WHERE f.quest_id = e.quest_id AND f.state = 'open')
      OR NOT EXISTS (SELECT 1 FROM phases p
                     WHERE p.id = e.verification_phase_id AND p.kind = 'verification'
                       AND p.state = 'complete')));

-- R-023: exactly one standing version per quest that has versions; every
-- bound version has citations, every unbound version has none
INSERT INTO seed_asserts
SELECT 'report_standing_and_binding_coherence', (
  SELECT sum(n) FROM (
    SELECT count(*) AS n FROM (
      SELECT quest_id FROM report_versions GROUP BY quest_id
      HAVING count(*) FILTER (WHERE standing) <> 1) bad
    UNION ALL
    SELECT count(*) AS n FROM report_versions rv
    WHERE (rv.bound_at IS NOT NULL AND NOT EXISTS (
             SELECT 1 FROM report_citations rc WHERE rc.report_version_id = rv.id))
       OR (rv.bound_at IS NULL AND EXISTS (
             SELECT 1 FROM report_citations rc WHERE rc.report_version_id = rv.id))) u);

-- R-026: the binding pass is DETERMINISTIC — re-derive ordinal->source from
-- (body ordinals) x (citation index) + (import manifest) and compare to the
-- stored citations of the bound version
INSERT INTO seed_asserts
WITH body AS (
  SELECT body FROM fixture_bodies WHERE tag = 'rv2'
), ordinals AS (
  SELECT DISTINCT (m[1])::integer AS ordinal
  FROM body, regexp_matches(body.body, '\[\^([0-9]+)\]', 'g') m
), cindex AS (
  SELECT qs.source_id,
         row_number() OVER (ORDER BY qs.added_at, qs.source_id) AS ordinal
  FROM quest_sources qs
  JOIN sources s ON s.id = qs.source_id AND s.user_id = qs.user_id
  WHERE qs.quest_id = 'b0000000-0000-4000-8000-000000000010'
    AND s.role = 'citable'
), manifest AS (
  SELECT (j->>'ordinal')::integer AS ordinal, j->>'source_urn' AS urn
  FROM phases p, jsonb_array_elements(p.result->'imports') j
  WHERE p.id = 'd0000000-0000-4000-8000-000000000015'
), derived AS (
  SELECT o.ordinal, ci.source_id FROM ordinals o JOIN cindex ci USING (ordinal)
  UNION ALL
  SELECT o.ordinal, s.id FROM ordinals o JOIN manifest ma USING (ordinal)
  JOIN sources s ON s.urn = ma.urn
), stored AS (
  SELECT rc.ordinal, coalesce(rc.source_id, rc.imported_source_id) AS source_id
  FROM report_citations rc
  WHERE rc.report_version_id = 'aa000000-0000-4000-8000-0000000000b2'
)
SELECT 'binding_pass_deterministic', (
  SELECT count(*) FROM (
    (SELECT ordinal, source_id FROM derived EXCEPT SELECT ordinal, source_id FROM stored)
    UNION ALL
    (SELECT ordinal, source_id FROM stored EXCEPT SELECT ordinal, source_id FROM derived)) d);

-- R-026: the footnote block regenerates byte-identically from the bound
-- citations (human-expanded global anchors; DR-12 format)
INSERT INTO seed_asserts
WITH gen AS (
  SELECT string_agg(
    '[^' || rc.ordinal || ']: ' || s.urn || ' — ' || s.title || ', ' || s.canonical_url
      || ', fetched ' || to_char(s.fetched_at, 'YYYY-MM-DD')
      || CASE WHEN rc.imported
              THEN ' [IMPORT from quest ' || rc.import_source_quest_id::text || ']'
              ELSE '' END,
    E'\n' ORDER BY rc.ordinal) AS block
  FROM report_citations rc
  JOIN sources s ON s.id = coalesce(rc.source_id, rc.imported_source_id)
  WHERE rc.report_version_id = 'aa000000-0000-4000-8000-0000000000b2'
), want AS (
  SELECT '[^2]: ' || s2.urn || ' — ' || s2.title || ', ' || s2.canonical_url
           || ', fetched ' || to_char(s2.fetched_at, 'YYYY-MM-DD') || E'\n'
       || '[^3]: ' || s3.urn || ' — ' || s3.title || ', ' || s3.canonical_url
           || ', fetched ' || to_char(s3.fetched_at, 'YYYY-MM-DD') || E'\n'
       || '[^5]: ' || s7.urn || ' — ' || s7.title || ', ' || s7.canonical_url
           || ', fetched ' || to_char(s7.fetched_at, 'YYYY-MM-DD')
           || ' [IMPORT from quest b0000000-0000-4000-8000-000000000001]' AS block
  FROM sources s2, sources s3, sources s7
  WHERE s2.id = 'a0000000-0000-4000-8000-000000000002'
    AND s3.id = 'a0000000-0000-4000-8000-000000000003'
    AND s7.id = 'a0000000-0000-4000-8000-000000000007')
SELECT 'footnote_block_regenerates', (
  SELECT count(*) FROM gen CROSS JOIN want WHERE gen.block IS DISTINCT FROM want.block);

-- R-026: the model never transcribes hashes — bodies carry no kb: URN
INSERT INTO seed_asserts
SELECT 'body_has_no_transcribed_urns', (
  SELECT count(*) FROM fixture_bodies fb
  WHERE fb.tag IN ('rv1', 'rv2') AND fb.body LIKE '%kb:%');

-- R-027: non-imported citations resolve inside the report quest's corpus;
-- imports carry the origin quest and resolve OUTSIDE it
INSERT INTO seed_asserts
SELECT 'citation_import_marking_honest', (
  SELECT count(*) FROM report_citations rc
  WHERE rc.report_version_id = 'aa000000-0000-4000-8000-0000000000b2'
    AND ((rc.imported = false AND NOT EXISTS (
           SELECT 1 FROM quest_sources qs
           WHERE qs.quest_id = rc.quest_id AND qs.source_id = rc.source_id))
      OR (rc.imported = true AND EXISTS (
           SELECT 1 FROM quest_sources qs
           WHERE qs.quest_id = rc.quest_id AND qs.source_id = rc.imported_source_id))));

-- R-021: grafted claims stamp the SOURCE quest; corpus inheritance is an
-- at-init copy (s7 staged into A after D's init: in A, not in D)
INSERT INTO seed_asserts
SELECT 'graft_stamps_and_corpus_snapshot', (
  (SELECT count(*) FROM claims c
   WHERE c.quest_id = 'b0000000-0000-4000-8000-000000000010'
     AND c.origin_quest_id IS NOT NULL
     AND c.origin_quest_id <> 'b0000000-0000-4000-8000-000000000001')
  + (SELECT count(*) FROM quest_sources qs
     WHERE qs.quest_id = 'b0000000-0000-4000-8000-000000000010'
       AND qs.source_id = 'a0000000-0000-4000-8000-000000000007')
  + CASE WHEN EXISTS (SELECT 1 FROM quest_sources qa
                      WHERE qa.quest_id = 'b0000000-0000-4000-8000-000000000001'
                        AND qa.source_id = 'a0000000-0000-4000-8000-000000000007')
            AND NOT EXISTS (SELECT 1 FROM quest_sources qd
                            WHERE qd.quest_id = 'b0000000-0000-4000-8000-000000000010'
                              AND qd.source_id = 'a0000000-0000-4000-8000-000000000007')
         THEN 0 ELSE 1 END);

-- R-025: visibility expectations for carol (member of kquest-lab; owns
-- nothing): readable = s3 (public), s4 (workspace), s6 (bob public), CC1
-- (workspace); NOT s1 (user-bob grant), s2, s7, CC2, CC3
INSERT INTO seed_asserts
WITH readable_sources AS (
  SELECT s.id FROM sources s WHERE s.user_id = '00000000-0000-4000-8000-000000000003'
  UNION
  SELECT rg.source_id FROM resource_grants rg
  WHERE rg.source_id IS NOT NULL
    AND (rg.is_public
      OR rg.grantee_user_id = '00000000-0000-4000-8000-000000000003'
      OR EXISTS (SELECT 1 FROM workspace_members wm
                 WHERE wm.workspace_id = rg.grantee_workspace_id
                   AND wm.user_id = '00000000-0000-4000-8000-000000000003'))
), readable_cclaims AS (
  SELECT cc.id FROM canonical_claims cc
  WHERE cc.user_id = '00000000-0000-4000-8000-000000000003'
  UNION
  SELECT rg.canonical_claim_id FROM resource_grants rg
  WHERE rg.canonical_claim_id IS NOT NULL
    AND (rg.is_public
      OR rg.grantee_user_id = '00000000-0000-4000-8000-000000000003'
      OR EXISTS (SELECT 1 FROM workspace_members wm
                 WHERE wm.workspace_id = rg.grantee_workspace_id
                   AND wm.user_id = '00000000-0000-4000-8000-000000000003'))
)
SELECT 'visibility_expectations_carol', (
  SELECT count(*) FROM readable_sources
  WHERE id NOT IN ('a0000000-0000-4000-8000-000000000003',
                   'a0000000-0000-4000-8000-000000000004',
                   'a0000000-0000-4000-8000-000000000006'))
+ (3 - (SELECT count(*) FROM readable_sources))
+ (SELECT count(*) FROM readable_cclaims
   WHERE id NOT IN ('80000000-0000-4000-8000-000000000001'))
+ (1 - (SELECT count(*) FROM readable_cclaims));

-- v_canonical_members: CC1={k4}, CC2={} (approved then reversed), CC3={d3}
INSERT INTO seed_asserts
SELECT 'canonical_membership_fixture', (
  SELECT count(*) FROM (
    SELECT canonical_claim_id, count(*) AS n FROM v_canonical_members
    GROUP BY canonical_claim_id) m
  WHERE (m.canonical_claim_id = '80000000-0000-4000-8000-000000000001' AND m.n <> 1)
     OR (m.canonical_claim_id = '80000000-0000-4000-8000-000000000002' AND m.n <> 0)
     OR (m.canonical_claim_id = '80000000-0000-4000-8000-000000000003' AND m.n <> 1))
+ CASE WHEN (SELECT count(*) FROM v_canonical_members) = 2 THEN 0 ELSE 1 END;

-- closure contract still holds after all I02 additions (L6 zero-assert)
INSERT INTO seed_asserts
SELECT 'no_bare_claims_after_i02', (
  SELECT count(*) FROM v_claim_closure WHERE bare);

SELECT * FROM seed_asserts ORDER BY check_name;
ALTER TABLE seed_asserts ADD CONSTRAINT ck_seed_i02_asserts CHECK (violations = 0);

DROP TABLE seed_asserts;
DROP TABLE fixture_bodies;

COMMIT;
