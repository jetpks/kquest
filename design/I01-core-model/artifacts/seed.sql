-- ============================================================================
-- kquest I01 core-model — seed fixtures (seed.sql)
-- ----------------------------------------------------------------------------
-- All snapshot texts are SYNTHETIC fixtures (they quote no real source).
-- Bodies live in fixture_bodies and are the single source of truth:
--   - snapshot_sha256 / snapshot_char_count are computed from the body,
--   - blob keys are generated columns (schema.sql),
--   - evidence span offsets are DERIVED via position(span IN body),
--   - chunk offsets come from the same paragraph walk that emits text,
--   - source URNs are minted in SQL per the DR-02 algorithm and claim URNs
--     per DR-06, using the pure-SQL base58 helper below (verified against a
--     python reference implementation; see Builder Report).
-- NOTE: authored without plpgsql — the local scratch server currently cannot
-- load procedural languages (client 18.7 libs vs 18.6 server binary), and
-- pure SQL keeps the fixture loadable on any PostgreSQL >= 13.
-- A verification table at the end re-proves, via a CHECK-constraint assert:
-- byte-exact span anchoring (L1), chunk verbatim substrings, sha
-- correctness, and both URN algorithms. Any violation aborts the seed load.
-- ============================================================================

BEGIN;

-- base58 (Bitcoin alphabet), pure SQL (recursive CTE divmod + zero prefix)
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

-- assert helper: insert (name, violations); the ALTER at the end fails the
-- whole load if any count is nonzero. This is the pure-SQL assert idiom used
-- throughout kquest artifacts (no procedural languages required).
CREATE TEMP TABLE seed_asserts (
  check_name text PRIMARY KEY,
  violations integer NOT NULL
);

-- ---------------------------------------------------------------------------
-- Fixture snapshot texts (synthetic; paragraphs separated by single \n)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE fixture_bodies (
  tag  text PRIMARY KEY,
  body text NOT NULL
);
INSERT INTO fixture_bodies (tag, body) VALUES
('s1', $fx$The t-statistic is the ratio of an estimated coefficient to its standard error.
Under the null hypothesis of a zero coefficient the t-statistic converges in distribution to the standard normal.
A confidence interval for a coefficient is the estimate plus or minus the critical value times the standard error.
Fixture text synthesized for the kquest I01 seed; it quotes no real source.$fx$),
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
('s5', $fx$This agenda note lists open questions rather than findings.
Which markets show the strongest cross-sectional momentum, and how large is the spread net of costs?
How do momentum crash dynamics interact with volatility regimes?
Fixture text synthesized for the kquest I01 seed; it quotes no real source.$fx$),
('s6', $fx$The fixture factor zoo note sketches twelve candidate factors for the second tenant.
Cross-sectional momentum appears alongside value, quality, and low volatility in the fixture taxonomy.
Fixture text synthesized for the kquest I01 seed; it quotes no real source.$fx$);

-- fixed fixture ids (stable so canonical-queries.sql can anchor on them)
CREATE TEMP TABLE fixture_sources (
  tag            text PRIMARY KEY,
  id             uuid NOT NULL,
  user_id        uuid NOT NULL,
  url            text NOT NULL,
  canonical_url  text NOT NULL,
  title          text NOT NULL,
  role           text NOT NULL,
  published_at   timestamptz,
  fetched_at     timestamptz NOT NULL
);
INSERT INTO fixture_sources VALUES
('s1', 'a0000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001',
 'https://fixture.example/definitions-note', 'https://fixture.example/definitions-note',
 'Fixture definitions note (synthetic)', 'citable', NULL, '2026-11-22T10:00:00+00'),
('s2', 'a0000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001',
 'https://fixture.example/momentum-primer?utm_source=newsletter', 'https://fixture.example/momentum-primer',
 'Fixture momentum primer (synthetic)', 'citable', '2026-01-15T00:00:00+00', '2026-11-22T10:02:00+00'),
('s3', 'a0000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000001',
 'https://fixture.example/costs-note', 'https://fixture.example/costs-note',
 'Fixture transaction costs note (synthetic)', 'citable', '2026-03-02T00:00:00+00', '2026-11-22T10:05:00+00'),
('s4', 'a0000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000001',
 'https://fixture.example/risk-model-docs', 'https://fixture.example/risk-model-docs',
 'Fixture risk model documentation (synthetic)', 'citable', NULL, '2026-11-22T10:07:00+00'),
('s5', 'a0000000-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000001',
 'https://fixture.example/research-agenda', 'https://fixture.example/research-agenda',
 'Fixture research agenda (synthetic, agenda role)', 'agenda', NULL, '2026-11-22T10:08:00+00'),
('s6', 'a0000000-0000-4000-8000-000000000006', '00000000-0000-4000-8000-000000000002',
 'https://fixture.example/factor-zoo', 'https://fixture.example/factor-zoo',
 'Fixture factor zoo note (tenant B, synthetic)', 'citable', NULL, '2026-11-22T09:00:00+00');

-- ---------------------------------------------------------------------------
-- users
-- ---------------------------------------------------------------------------
INSERT INTO users (id, handle, display_name) VALUES
('00000000-0000-4000-8000-000000000001', 'alice', 'Alice Fixture'),
('00000000-0000-4000-8000-000000000002', 'bob',   'Bob Fixture');

-- ---------------------------------------------------------------------------
-- sources — sha/char-count/urn computed from the fixture body (DR-02).
-- raw_sha256 hashes a synthetic raw envelope (the raw-response fixture).
-- s2's url carries a tracking param that canonical_url strips (DR-03 demo).
-- ---------------------------------------------------------------------------
INSERT INTO sources
  (id, user_id, url, canonical_url, urn, title, role, published_at, fetched_at,
   snapshot_sha256, raw_sha256, snapshot_char_count)
SELECT fs.id, fs.user_id, fs.url, fs.canonical_url,
       'kb:src:' || substr(pg_temp.kb_base58(
         sha256(convert_to(fs.canonical_url || m.snap_sha, 'UTF8'))), 1, 10),
       fs.title, fs.role, fs.published_at, fs.fetched_at,
       m.snap_sha,
       encode(sha256(convert_to('raw-envelope:' || fs.tag || ':' || m.body, 'UTF8')), 'hex'),
       m.chars
FROM fixture_sources fs
JOIN (SELECT tag, body, encode(sha256(convert_to(body, 'UTF8')), 'hex') AS snap_sha,
             char_length(body) AS chars
      FROM fixture_bodies) m USING (tag);

-- ---------------------------------------------------------------------------
-- chunk strategies (config rows) + quests + corpus membership
-- ---------------------------------------------------------------------------
INSERT INTO chunk_strategies (id, name, version, target_chars, overlap_chars, paragraph_aligned, notes) VALUES
('c0000000-0000-4000-8000-000000000001', 'para-800', 1, 800, 0, true, 'paragraph-aligned, target 800 chars (fixture default)'),
('c0000000-0000-4000-8000-000000000002', 'para-400', 1, 400, 0, true, 'paragraph-aligned, target 400 chars (re-chunk generation demo)');

INSERT INTO quests
  (id, user_id, topic, state, provenance_kind, source_quest_id,
   web_call_budget, token_budget, spend_budget_usd, model_config, process_config) VALUES
('b0000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001',
 'Cross-sectional momentum in equity returns (fixture)', 'active', 'fresh', NULL,
 1024, 50000000, 40.0000,
 '{"decompose":"glm-5.3","descent":"glm-5.3","synthesis":"glm-5.3","verification":"glm-5.3"}'::jsonb,
 '{}'::jsonb),
('b0000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001',
 'Momentum continuation quest (fixture, inherits corpus)', 'complete', 'from_corpus',
 'b0000000-0000-4000-8000-000000000001',
 512, 20000000, 15.0000,
 '{"decompose":"glm-5.3","descent":"glm-5.3"}'::jsonb,
 '{}'::jsonb),
('b0000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000002',
 'Factor taxonomy survey (tenant B fixture)', 'active', 'fresh', NULL,
 256, 10000000, 10.0000,
 '{"decompose":"qwen3.8-flash-next"}'::jsonb,
 '{}'::jsonb);

INSERT INTO quest_sources (quest_id, source_id, user_id) VALUES
-- quest A stages s1..s5 (incl. the agenda note)
('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001'),
('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001'),
('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000001'),
('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000001'),
('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000001'),
-- quest B inherits the citable corpus (from_corpus)
('b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001'),
('b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001'),
('b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000001'),
('b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000001'),
-- tenant B quest stages its own source
('b0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000006', '00000000-0000-4000-8000-000000000002');

-- ---------------------------------------------------------------------------
-- phases + sessions (usage chain quest→phase→session complete: DR-13)
-- ---------------------------------------------------------------------------
INSERT INTO phases
  (id, user_id, quest_id, kind, round_no, attempt_no, state,
   started_at, ended_at, wall_timeout_s, result, frontier_open, frontier_mass) VALUES
('d0000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'decompose', 1, 1, 'complete',
 '2026-11-22T10:05:00+00', '2026-11-22T11:40:00+00', 2700,
 '{"summary":"fixture decompose round 1: 5 staged sources, 4 citable mined"}'::jsonb, 2, 32),
('d0000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'descent', 1, 1, 'running',
 '2026-11-22T11:41:00+00', NULL, 2700, NULL, NULL, NULL),
('d0000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000002',
 'b0000000-0000-4000-8000-000000000003', 'decompose', 1, 1, 'complete',
 '2026-11-22T09:00:00+00', '2026-11-22T09:31:00+00', 2700,
 '{"summary":"fixture tenant-B decompose"}'::jsonb, 0, 0);

INSERT INTO sessions
  (id, user_id, quest_id, phase_id, mode, driver, model, transcript_blob_key, started_at, ended_at) VALUES
('e0000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001',
 'autonomous', 'orchestrator', 'glm-5.3',
 'sessions/e0000000-0000-4000-8000-000000000001/transcript.jsonl',
 '2026-11-22T10:05:00+00', '2026-11-22T11:40:00+00'),
('e0000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000002',
 'b0000000-0000-4000-8000-000000000003', 'd0000000-0000-4000-8000-000000000003',
 'interactive', 'operator', 'qwen3.8-flash-next',
 'sessions/e0000000-0000-4000-8000-000000000002/transcript.jsonl',
 '2026-11-22T09:00:00+00', '2026-11-22T09:31:00+00');

-- ---------------------------------------------------------------------------
-- claims (K-nodes). URNs minted per DR-06: kb:claim:base58(
--   sha256(quest_uuid_string || canonical_text))[0:10]. k6/k7 stay bare but
-- carry OPEN frontier entries — legal mid-flight states (closure third arm).
-- ---------------------------------------------------------------------------
INSERT INTO claims
  (id, user_id, quest_id, quest_seq, text, terminal_type, terminal_basis, urn,
   origin_quest_id, created_session_id)
SELECT c.id, c.user_id, c.quest_id, c.quest_seq, c.text, c.terminal_type, c.terminal_basis,
       'kb:claim:' || substr(pg_temp.kb_base58(
         sha256(convert_to(c.quest_id::text || norm.canonical_text, 'UTF8'))), 1, 10),
       c.origin_quest_id, c.created_session_id
FROM (VALUES
('f0000000-0000-4000-8000-000000000001'::uuid, '00000000-0000-4000-8000-000000000001'::uuid,
 'b0000000-0000-4000-8000-000000000001'::uuid, 1,
 'A t-statistic is the ratio of an estimated coefficient to its standard error.',
 'definitional-mathematical'::text, 'Definition of the t-statistic; a mathematical identity.'::text,
 NULL::uuid, 'e0000000-0000-4000-8000-000000000001'::uuid),
('f0000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001'::uuid,
 'b0000000-0000-4000-8000-000000000001'::uuid, 2,
 'In the fixture literature the cross-sectional momentum spread is about one percent per month before costs.',
 'primary-empirical'::text, 'Fixture primer WML spread table (synthetic primary).'::text,
 NULL::uuid, 'e0000000-0000-4000-8000-000000000001'::uuid),
('f0000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000001'::uuid,
 'b0000000-0000-4000-8000-000000000001'::uuid, 3,
 'Whether momentum survives net of post-publication costs remains unresolved.',
 'residual-uncertainty'::text, 'Flagged residual: no fixture source resolves net-of-cost persistence after publication.'::text,
 NULL::uuid, 'e0000000-0000-4000-8000-000000000001'::uuid),
('f0000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000001'::uuid,
 'b0000000-0000-4000-8000-000000000001'::uuid, 4,
 'Momentum profits persist after controlling for market beta in the fixture literature.',
 NULL::text, NULL::text,
 NULL::uuid, 'e0000000-0000-4000-8000-000000000001'::uuid),
('f0000000-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000001'::uuid,
 'b0000000-0000-4000-8000-000000000001'::uuid, 5,
 'Net-of-cost momentum is modest but positive in the fixture market model.',
 NULL::text, NULL::text,
 NULL::uuid, 'e0000000-0000-4000-8000-000000000001'::uuid),
('f0000000-0000-4000-8000-000000000006', '00000000-0000-4000-8000-000000000001'::uuid,
 'b0000000-0000-4000-8000-000000000001'::uuid, 6,
 'Momentum crash dynamics are idiosyncratic to individual stocks.',
 NULL::text, NULL::text,
 NULL::uuid, 'e0000000-0000-4000-8000-000000000001'::uuid),
('f0000000-0000-4000-8000-000000000007', '00000000-0000-4000-8000-000000000001'::uuid,
 'b0000000-0000-4000-8000-000000000001'::uuid, 7,
 'The magnitude of cross-sectional momentum outside US equities is unknown.',
 NULL::text, NULL::text,
 NULL::uuid, 'e0000000-0000-4000-8000-000000000001'::uuid),
-- quest B graft: identical canonical text to k4 (Q4 dedup-candidate anchor)
('f0000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000001'::uuid,
 'b0000000-0000-4000-8000-000000000002'::uuid, 1,
 'Momentum profits persist after controlling for market beta in the fixture literature.',
 NULL::text, NULL::text,
 'b0000000-0000-4000-8000-000000000001'::uuid, NULL::uuid)
) AS c(id, user_id, quest_id, quest_seq, text, terminal_type, terminal_basis,
       origin_quest_id, created_session_id),
LATERAL (SELECT btrim(regexp_replace(normalize(c.text, NFC), '[ \t\n\r\f\v]+', ' ', 'g'),
                      ' ' || chr(9) || chr(10) || chr(13) || chr(11) || chr(12)) AS canonical_text) norm;

-- ---------------------------------------------------------------------------
-- evidence (E-nodes). Offsets DERIVED: span_start = position(span IN body)-1.
-- Every span is a single-line verbatim fragment (PoC span discipline).
-- Pre-assert: every span literal occurs in its fixture body.
-- ---------------------------------------------------------------------------
INSERT INTO seed_asserts (check_name, violations)
SELECT 'evidence_span_present_in_body', count(*)
FROM (VALUES
  ('s2', $sp$cross-sectional winners outperformed losers by about one percent per month$sp$),
  ('s1', $sp$The t-statistic is the ratio of an estimated coefficient to its standard error.$sp$),
  ('s2', $sp$Momentum spreads survive beta controls in the fixture regression table$sp$),
  ('s4', $sp$Momentum strategy drawdowns cluster in market rebound regimes$sp$),
  ('s3', $sp$Round-trip transaction costs consume roughly 40 basis points of the gross momentum spread$sp$),
  ('s2', $sp$Reversal at the one-month horizon partially offsets the gross spread$sp$)
) AS e(source_tag, span_literal)
JOIN fixture_bodies fb ON fb.tag = e.source_tag
WHERE position(e.span_literal IN fb.body) = 0;
ALTER TABLE seed_asserts ADD CONSTRAINT ck_seed_spans_present CHECK (violations = 0);

INSERT INTO evidence
  (id, user_id, quest_id, source_id, source_anchorable, snapshot_char_count,
   span_start, span_end, span_text, reading, created_session_id)
SELECT e.id, fs.user_id, e.quest_id, fs.id, (fs.role = 'citable'), char_length(fb.body),
       position(e.span_literal IN fb.body) - 1,
       position(e.span_literal IN fb.body) - 1 + char_length(e.span_literal),
       e.span_literal, e.reading, e.created_session_id
FROM (VALUES
  -- e1: s2 primer -> supports k2 (magnitude)
  ('10000000-0000-4000-8000-000000000001'::uuid, 's2', 'b0000000-0000-4000-8000-000000000001'::uuid,
   $sp$cross-sectional winners outperformed losers by about one percent per month$sp$,
   'fixture primer reports a roughly one percent per month WML spread',
   'e0000000-0000-4000-8000-000000000001'::uuid),
  -- e2: s1 definitions -> supports k1 (the definitional terminal)
  ('10000000-0000-4000-8000-000000000002'::uuid, 's1', 'b0000000-0000-4000-8000-000000000001'::uuid,
   $sp$The t-statistic is the ratio of an estimated coefficient to its standard error.$sp$,
   'the fixture definitions note states the t-statistic identity verbatim',
   'e0000000-0000-4000-8000-000000000001'::uuid),
  -- e3: s2 primer -> supports k4 (beta control) — shares s2 with e1
  --     (citation-ancestry dependence demo for canonical query Q2)
  ('10000000-0000-4000-8000-000000000003'::uuid, 's2', 'b0000000-0000-4000-8000-000000000001'::uuid,
   $sp$Momentum spreads survive beta controls in the fixture regression table$sp$,
   'beta-control regression survives with t-statistics above three',
   'e0000000-0000-4000-8000-000000000001'::uuid),
  -- e4: s4 risk docs -> CONTRADICTS k6 (crash idiosyncrasy)
  ('10000000-0000-4000-8000-000000000004'::uuid, 's4', 'b0000000-0000-4000-8000-000000000001'::uuid,
   $sp$Momentum strategy drawdowns cluster in market rebound regimes$sp$,
   'drawdowns cluster at the strategy level in rebound regimes, not per-stock',
   'e0000000-0000-4000-8000-000000000001'::uuid),
  -- e5: s3 costs -> supports k5
  ('10000000-0000-4000-8000-000000000005'::uuid, 's3', 'b0000000-0000-4000-8000-000000000001'::uuid,
   $sp$Round-trip transaction costs consume roughly 40 basis points of the gross momentum spread$sp$,
   'round-trip costs consume roughly 40 basis points of the gross spread',
   'e0000000-0000-4000-8000-000000000001'::uuid),
  -- e6: s2 primer -> supports k5 (second, independent source for k5)
  ('10000000-0000-4000-8000-000000000006'::uuid, 's2', 'b0000000-0000-4000-8000-000000000001'::uuid,
   $sp$Reversal at the one-month horizon partially offsets the gross spread$sp$,
   'short-horizon reversal trims the gross spread toward a modest net level',
   'e0000000-0000-4000-8000-000000000001'::uuid)
) AS e(id, source_tag, quest_id, span_literal, reading, created_session_id)
JOIN fixture_sources fs ON fs.tag = e.source_tag
JOIN fixture_bodies  fb ON fb.tag = fs.tag;

-- evidence -> claim edges (ordered)
INSERT INTO evidence_edges
  (id, user_id, quest_id, evidence_id, relation, claim_id, position) VALUES
('20000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
 'supports', 'f0000000-0000-4000-8000-000000000002', 1),
('20000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000002',
 'supports', 'f0000000-0000-4000-8000-000000000001', 1),
('20000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000003',
 'supports', 'f0000000-0000-4000-8000-000000000004', 1),
('20000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000004',
 'contradicts', 'f0000000-0000-4000-8000-000000000006', 1),
('20000000-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000005',
 'supports', 'f0000000-0000-4000-8000-000000000005', 1),
('20000000-0000-4000-8000-000000000006', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000006',
 'supports', 'f0000000-0000-4000-8000-000000000005', 2);

-- claim -> claim derivations (ordered)
INSERT INTO claim_derivations
  (id, user_id, quest_id, claim_id, parent_claim_id, position) VALUES
('30000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000004',
 'f0000000-0000-4000-8000-000000000001', 1),
('30000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000004',
 'f0000000-0000-4000-8000-000000000002', 2),
('30000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000005',
 'f0000000-0000-4000-8000-000000000004', 1);

-- frontier entries (history retained; distinct needs; open+closed mix)
INSERT INTO frontier_entries
  (id, user_id, quest_id, claim_id, need, uncertainty, relevance, state,
   spawned_by_phase_id, opened_at, closed_at, closure_type) VALUES
('40000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000006',
 'primary empirical evidence on momentum crash frequency and depth by regime',
 5, 4, 'open', 'd0000000-0000-4000-8000-000000000001',
 '2026-11-22T10:30:00+00', NULL, NULL),
('40000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000007',
 'cross-market estimates of cross-sectional momentum magnitude',
 3, 4, 'open', 'd0000000-0000-4000-8000-000000000001',
 '2026-11-22T10:41:00+00', NULL, NULL),
('40000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000005',
 'net-of-cost momentum estimates under realistic fee schedules',
 2, 3, 'closed', 'd0000000-0000-4000-8000-000000000001',
 '2026-11-22T10:50:00+00', '2026-11-22T11:10:00+00', 'internal'),
('40000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000004',
 'regression evidence that momentum survives beta controls',
 4, 5, 'closed', 'd0000000-0000-4000-8000-000000000001',
 '2026-11-22T10:20:00+00', '2026-11-22T10:55:00+00', 'fetch');

-- conflict: gross-vs-net divergence on k2 between s2 and s3
INSERT INTO conflicts
  (id, user_id, quest_id, claim_id, divergence, resolution_hypothesis, created_session_id) VALUES
('50000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000002',
 'The fixture primer states a gross spread of about one percent per month while the costs note implies the net spread is roughly sixty basis points once round-trip costs are included.',
 'Reframe both figures net of costs; the divergence is gross-versus-net framing rather than contradicting estimates.',
 'e0000000-0000-4000-8000-000000000001');

INSERT INTO conflict_sources (conflict_id, source_id, user_id, source_anchorable) VALUES
('50000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000002',
 '00000000-0000-4000-8000-000000000001', true),
('50000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000003',
 '00000000-0000-4000-8000-000000000001', true);

-- ---------------------------------------------------------------------------
-- chunks — paragraph-aligned, offsets from the same walk that emits text.
--   para-800 v1 over citable sources s1..s4; para-400 v1 over the AGENDA
--   source s5 (agenda sources are readable/chunkable — never anchorable).
-- ---------------------------------------------------------------------------
INSERT INTO chunks
  (source_id, user_id, strategy_id, ordinal, text,
   char_start, char_end, snapshot_char_count, source_anchorable)
SELECT fs.id, fs.user_id,
       CASE WHEN fs.tag = 's5' THEN 'c0000000-0000-4000-8000-000000000002'::uuid
            ELSE 'c0000000-0000-4000-8000-000000000001'::uuid END,
       p.ord,
       p.para,
       p.startoff,
       p.startoff + char_length(p.para),
       char_length(fb.body),
       (fs.tag <> 's5')
FROM fixture_sources fs
JOIN fixture_bodies fb ON fb.tag = fs.tag
CROSS JOIN LATERAL (
  SELECT t.para AS para, t.o AS ord,
         (SELECT coalesce(sum(char_length(prev.para) + 1), 0)
          FROM unnest(string_to_array(fb.body, E'\n')) WITH ORDINALITY AS prev(para, o)
          WHERE prev.o < t.o) AS startoff
  FROM unnest(string_to_array(fb.body, E'\n')) WITH ORDINALITY AS t(para, o)
) p
WHERE fs.tag IN ('s1', 's2', 's3', 's4', 's5')
  AND char_length(p.para) > 0;

-- ---------------------------------------------------------------------------
-- tool_calls (verbatim audit, L8) — accepted ops, one REFUSED op recorded
-- in the PoC refusal shape, a frontier op, a web op, and a status op.
-- ---------------------------------------------------------------------------
INSERT INTO tool_calls
  (id, user_id, quest_id, session_id, seq, tool, op, args, result, ok, error_class, created_at) VALUES
('60000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000001',
 1, 'graph', 'node_add',
 '{"label":"claim","fields":{"text":"Momentum profits persist after controlling for market beta in the fixture literature."}}'::jsonb,
 '{"ok":true,"alias":"K4"}'::jsonb, true, NULL, '2026-11-22T10:19:00+00'),
('60000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000001',
 2, 'graph', 'node_add',
 '{"label":"evidence","fields":{"src":"C2","span":"Momentum spreads survive beta controls in the fixture regression table with line breaks","reading":"beta-control regression survives"}}'::jsonb,
 '{"error":"GRAPH_INVALID: unanchored span: span not present in snapshot C2"}'::jsonb,
 false, 'GRAPH_INVALID', '2026-11-22T10:21:00+00'),
('60000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000001',
 3, 'graph', 'frontier_add',
 '{"claim":"K6","need":"primary empirical evidence on momentum crash frequency and depth by regime","uncertainty":5,"relevance":4}'::jsonb,
 '{"ok":true,"entry":"F1"}'::jsonb, true, NULL, '2026-11-22T10:30:00+00'),
('60000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000001',
 4, 'web', 'fetch_save',
 '{"url":"https://fixture.example/costs-note"}'::jsonb,
 '{"ok":true,"source":"kb:src","budget":{"web_calls_used":1}}'::jsonb, true, NULL, '2026-11-22T10:04:00+00'),
('60000000-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000002',
 'b0000000-0000-4000-8000-000000000003', 'e0000000-0000-4000-8000-000000000002',
 1, 'graph', 'status',
 '{}'::jsonb,
 '{"claims":0,"evidence":0,"frontier_open":0,"violations":0}'::jsonb, true, NULL, '2026-11-22T09:01:00+00');

-- usage ledger (D10): llm + embedding kinds; local model with NULL cost
INSERT INTO usage_events
  (id, user_id, quest_id, phase_id, session_id, kind, model,
   input_tokens, output_tokens, cost_usd, created_at) VALUES
('70000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001',
 'e0000000-0000-4000-8000-000000000001', 'llm', 'glm-5.3', 81234, 2100, 0.042130, '2026-11-22T10:06:00+00'),
('70000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001',
 'e0000000-0000-4000-8000-000000000001', 'llm', 'glm-5.3', 96410, 3220, 0.051870, '2026-11-22T11:00:00+00'),
('70000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000002',
 'b0000000-0000-4000-8000-000000000003', 'd0000000-0000-4000-8000-000000000003',
 'e0000000-0000-4000-8000-000000000002', 'llm', 'qwen3.8-flash-next', 45320, 1880, NULL, '2026-11-22T09:10:00+00'),
('70000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001',
 'e0000000-0000-4000-8000-000000000001', 'embedding', 'bge-m3', 12400, 0, 0.000620, '2026-11-22T10:45:00+00');

-- ============================================================================
-- SELF-VERIFICATION — re-proves the anchoring + identity laws against the
-- fixture bodies; the ALTER fails (and aborts the transaction) on any
-- nonzero violation count. (Hard seed minimums are asserted by check-ddl.sh,
-- which is the executable spec of the seed contract.)
-- ============================================================================
INSERT INTO seed_asserts (check_name, violations) VALUES
 -- L1: every evidence span is byte-exact at its recorded offsets AND sits
 -- exactly where position() says it does
 ('evidence_span_byte_exact', (
   SELECT count(*) FROM evidence e
   JOIN fixture_sources fs ON fs.id = e.source_id
   JOIN fixture_bodies  fb ON fb.tag = fs.tag
   WHERE substring(fb.body FROM e.span_start + 1 FOR e.span_end - e.span_start) <> e.span_text
      OR position(e.span_text IN fb.body) - 1 <> e.span_start)),
 -- L1/L10: chunks are verbatim substrings at their offsets
 ('chunk_verbatim_at_offsets', (
   SELECT count(*) FROM chunks c
   JOIN fixture_sources fs ON fs.id = c.source_id
   JOIN fixture_bodies  fb ON fb.tag = fs.tag
   WHERE substring(fb.body FROM c.char_start + 1 FOR c.char_end - c.char_start) <> c.text)),
 -- DR-02: source sha + urn re-derivation
 ('source_sha256_matches_body', (
   SELECT count(*) FROM sources s
   JOIN fixture_sources fs ON fs.id = s.id
   JOIN fixture_bodies  fb ON fb.tag = fs.tag
   WHERE encode(sha256(convert_to(fb.body, 'UTF8')), 'hex') <> s.snapshot_sha256::text)),
 ('source_urn_algorithm_dr02', (
   SELECT count(*) FROM sources s
   JOIN fixture_sources fs ON fs.id = s.id
   JOIN fixture_bodies  fb ON fb.tag = fs.tag
   WHERE 'kb:src:' || substr(pg_temp.kb_base58(
           sha256(convert_to(s.canonical_url || s.snapshot_sha256::text, 'UTF8'))), 1, 10) <> s.urn)),
 -- DR-06: claim urn re-derivation from quest salt + canonical_text
 ('claim_urn_algorithm_dr06', (
   SELECT count(*) FROM claims c
   WHERE 'kb:claim:' || substr(pg_temp.kb_base58(
           sha256(convert_to(c.quest_id::text || c.canonical_text, 'UTF8'))), 1, 10) <> c.urn)),
 -- snapshot_char_count pinned copies equal char_length(body)
 ('snapshot_char_count_accurate', (
   SELECT count(*) FROM sources s
   JOIN fixture_sources fs ON fs.id = s.id
   JOIN fixture_bodies  fb ON fb.tag = fs.tag
   WHERE s.snapshot_char_count <> char_length(fb.body)));

SELECT * FROM seed_asserts ORDER BY check_name;
ALTER TABLE seed_asserts ADD CONSTRAINT ck_seed_asserts_all_zero CHECK (violations = 0);

-- fixture counts (informational)
SELECT 'users'         AS what, count(*) AS n FROM users
UNION ALL SELECT 'quests',        count(*) FROM quests
UNION ALL SELECT 'sources',       count(*) FROM sources
UNION ALL SELECT 'chunks',        count(*) FROM chunks
UNION ALL SELECT 'claims',        count(*) FROM claims
UNION ALL SELECT 'evidence',      count(*) FROM evidence
UNION ALL SELECT 'derivations',   count(*) FROM claim_derivations
UNION ALL SELECT 'frontier',      count(*) FROM frontier_entries
UNION ALL SELECT 'conflicts',     count(*) FROM conflicts
UNION ALL SELECT 'tool_calls',    count(*) FROM tool_calls
UNION ALL SELECT 'usage_events',  count(*) FROM usage_events;

DROP TABLE seed_asserts;
DROP TABLE fixture_bodies;
DROP TABLE fixture_sources;

COMMIT;
