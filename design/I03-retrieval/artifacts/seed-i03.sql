-- ============================================================================
-- kquest I03 retrieval — seed fixtures (seed-i03.sql)
-- ----------------------------------------------------------------------------
-- Loads after I01 schema+seed and I02 schema-i02+seed-i02 (both read-only
-- law) plus schema-i03.sql. Everything here is SYNTHETIC fixture data.
--
-- Contents:
--   1. the synthetic-vector encoder pg_temp.synth_vec (methodology DR-15:
--      deterministic hashing-trick token vectors — sha256-derived, so
--      similar fixture texts yield nearby vectors; proves the QUERY
--      machinery, never model quality).
--   2. embedding_models registry rows: 3 registrations — active dense
--      fixture (bge-m3-1024, the concrete generated table), active A/B
--      challenger (minilm-ab-384, its own table), and a RETIRED model
--      (nomic-s1-768: jobs failed + table never/dropped, the legal
--      terminal retire state).
--   3. one new I01-table fixture row (tenant-B claim in quest C — the
--      cross-user scoping probe's live target; URN minted per I01 DR-06).
--   4. pipeline sessions + usage_events (embedding spend into the I01
--      ledger, D10) + 17 embed_jobs covering every lifecycle state
--      (pending / running / complete / failed), an idem-retry pair, and a
--      re-embed generation running mid-flight (done < total: resumable).
--   5. vectors: chunk / claim / frontier_need rows in the active 1024d
--      table; claim rows in the 384d A/B table.
--   6. self-verification (temp-table assert idiom): every vector
--      re-derives byte-identically from its embedded_text; every
--      embedded_text byte-matches its target's current text (rebuild
--      law, L10); job/model/usage coherence.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- pg_temp.kb_base58 — same pure-SQL helper as I01/I02 seeds (claim URN).
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- pg_temp.synth_vec — the deterministic SYNTHETIC fixture-vector encoder
--   (DR-15; DESIGN §14). Methodology, honestly stated:
--   - tokenize: lowercase, split on non-alphanumerics, keep tokens of
--     length >= 3 minus a small stoplist. The stoplist also drops the
--     fixture corpus's shared boilerplate ('fixture', 'kquest', 'seed',
--     ...) so similarity reflects TOPIC vocabulary, not shared scaffolding.
--   - per token: a deterministic pseudo-random direction in R^dims derived
--     from sha256(token || block_index): each 256-bit block yields 8
--     signed dims (4 bytes per dim), so a token's direction is fully
--     determined by its bytes — nothing random at run time.
--   - document vector = normalized sum of token directions. Texts sharing
--     vocabulary land near each other (high cosine); disjoint vocabularies
--     land near-orthogonal. IDENTICAL texts yield IDENTICAL vectors
--     (cosine distance exactly 0) — the property the query families assert.
--   LIMITS (recorded in DR-15): this is a hashing-trick LEXICAL encoder.
--     It proves the query machinery (operators, ranks, fusion, scoping,
--     constraints) — it is NOT a semantic model: no synonymy, no
--     paraphrase beyond shared tokens, and similarity magnitudes are NOT
--     calibrated to any real embedding model. Thresholds (dedup floor,
--     relevance cutoffs) are policy constants for the tool layer to
--     calibrate against a real registry model (ENTRY 5).
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
),
blocks AS (
  SELECT tok, b, sha256(convert_to(tok, 'UTF8') || int4send(b)) AS h
  FROM toks CROSS JOIN generate_series(0, (dims - 1) / 8) AS b
),
dirs AS (
  SELECT blk.b * 8 + j AS i,
         ((get_byte(blk.h, j * 4)::bigint * 16777216
          + get_byte(blk.h, j * 4 + 1)::bigint * 65536
          + get_byte(blk.h, j * 4 + 2)::bigint * 256
          + get_byte(blk.h, j * 4 + 3)::bigint
          )::double precision - 2147483648.0) / 2147483648.0 AS x
  FROM blocks blk CROSS JOIN generate_series(0, 7) AS j
  WHERE blk.b * 8 + j < dims
),
sums AS (SELECT i, sum(x) AS s FROM dirs GROUP BY i),
norm AS (SELECT sqrt(sum(s * s)) AS n FROM sums)
SELECT ('[' || string_agg(to_char(s.s / nullif(n.n, 0), 'FM0.00000000'), ',' ORDER BY s.i)
        || ']')::vector
FROM sums s CROSS JOIN norm n
$fn$;

CREATE TEMP TABLE seed_asserts (
  check_name text PRIMARY KEY,
  violations integer NOT NULL
);

-- ---------------------------------------------------------------------------
-- 1. embedding_models — registry fixtures (R-028)
--   m1: the D4 first registration — bge-m3 via OpenRouter, dense 1024d
--       cosine; its generated table emb_bge_m3_1024 ships in schema-i03.
--   m2: the A/B CHALLENGER — active, 384d, local TEI endpoint (nullable
--       cost class); its table emb_minilm_ab_384 ships in schema-i03.
--       A/B = two active rows + queries choosing by registry id: data, not
--       code (queries-i03.sql family a4).
--   m3: RETIRED — provider decommissioned mid-backfill (its embed job j15
--       failed, below); table never generated past the probe stage, so the
--       retire pair (status + retired_at) is the legal terminal state.
-- ---------------------------------------------------------------------------
INSERT INTO embedding_models
  (id, slug, wire_name, provider, endpoint, api_key_ref, dimensions, metric,
   batch_max_texts, input_max_chars, status, retired_at, table_name, registered_at) VALUES
('92000000-0000-4000-8000-000000000001', 'bge-m3-1024', 'bge-m3', 'openrouter',
 'https://openrouter.ai/api/v1/embeddings', 'env:OPENROUTER_API_KEY', 1024, 'cosine',
 64, 8192, 'active', NULL, 'emb_bge_m3_1024', '2026-11-22T09:00:00+00'),
('92000000-0000-4000-8000-000000000002', 'minilm-ab-384', 'sentence-transformers/all-MiniLM-L6-v2', 'tei-local',
 'http://tei-local.example/v1/embeddings', NULL, 384, 'cosine',
 128, 8192, 'active', NULL, 'emb_minilm_ab_384', '2026-11-22T09:05:00+00'),
('92000000-0000-4000-8000-000000000003', 'nomic-s1-768', 'nomic-embed-text-v1.5', 'tei-local',
 'http://tei-local.example/v1/embeddings', NULL, 768, 'cosine',
 128, 8192, 'retired', '2026-11-22T09:55:00+00', 'emb_nomic_s1_768', '2026-11-22T09:10:00+00');

-- ---------------------------------------------------------------------------
-- 2. tenant-B fixture claim (quest C, bob) — the live target for the
--    cross-user scoping probes: alice's retrieval/dedup queries must never
--    return it; bob's do. URN minted per I01 DR-06 (quest-salted).
-- ---------------------------------------------------------------------------
INSERT INTO claims
  (id, user_id, quest_id, quest_seq, text, terminal_type, terminal_basis, urn,
   origin_quest_id, created_session_id)
SELECT 'f0000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000002',
       'b0000000-0000-4000-8000-000000000003', 1,
       'Cross-sectional momentum ranks beside value and quality in the tenant-B fixture taxonomy.',
       'residual-uncertainty',
       'No tenant-B fixture source ranks the taxonomy factors; flagged residual at decompose.',
       'kb:claim:' || substr(pg_temp.kb_base58(
         sha256(convert_to('b0000000-0000-4000-8000-000000000003'::uuid::text || norm.canonical_text, 'UTF8'))), 1, 10),
       NULL, 'e0000000-0000-4000-8000-000000000002'
FROM (SELECT btrim(regexp_replace(normalize(
        'Cross-sectional momentum ranks beside value and quality in the tenant-B fixture taxonomy.', NFC),
        '[ \t\n\r\f\v]+', ' ', 'g'), ' ' || chr(9) || chr(10) || chr(13) || chr(11) || chr(12)) AS canonical_text) norm;

-- ---------------------------------------------------------------------------
-- 3. pipeline sessions (one per quest's corpus work) + embedding spend rows
--    in the I01 usage ledger (D10: every embedding call accounted; the
--    model column is the audit ECHO of the registry wire name — a record,
--    never an access path; DR-01). Local TEI spend is cost-NULL (I01 DR-14
--    class). All embed-session model values are embedding wire names.
-- ---------------------------------------------------------------------------
INSERT INTO sessions
  (id, user_id, quest_id, phase_id, mode, driver, model, transcript_blob_key,
   started_at, ended_at) VALUES
('e0000000-0000-4000-8000-000000000021', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002',
 'autonomous', 'orchestrator', 'bge-m3',
 'sessions/e0000000-0000-4000-8000-000000000021/transcript.jsonl',
 '2026-11-22T11:45:00+00', '2026-11-22T12:35:00+00'),
('e0000000-0000-4000-8000-000000000022', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000002', 'd0000000-0000-4000-8000-000000000004',
 'autonomous', 'orchestrator', 'bge-m3',
 'sessions/e0000000-0000-4000-8000-000000000022/transcript.jsonl',
 '2026-11-22T12:10:00+00', '2026-11-22T12:16:00+00'),
('e0000000-0000-4000-8000-000000000023', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'd0000000-0000-4000-8000-000000000011',
 'autonomous', 'orchestrator', 'bge-m3',
 'sessions/e0000000-0000-4000-8000-000000000023/transcript.jsonl',
 '2026-11-22T12:10:00+00', '2026-11-22T12:16:00+00'),
('e0000000-0000-4000-8000-000000000024', '00000000-0000-4000-8000-000000000002',
 'b0000000-0000-4000-8000-000000000003', 'd0000000-0000-4000-8000-000000000003',
 'autonomous', 'orchestrator', 'bge-m3',
 'sessions/e0000000-0000-4000-8000-000000000024/transcript.jsonl',
 '2026-11-22T09:20:00+00', '2026-11-22T09:26:00+00');

INSERT INTO usage_events
  (id, user_id, quest_id, phase_id, session_id, kind, model,
   input_tokens, output_tokens, cost_usd, created_at) VALUES
('70000000-0000-4000-8000-000000000021', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002',
 'e0000000-0000-4000-8000-000000000021', 'embedding', 'bge-m3', 17231, 0, 0.008620, '2026-11-22T11:52:00+00'),
('70000000-0000-4000-8000-000000000022', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002',
 'e0000000-0000-4000-8000-000000000021', 'embedding', 'bge-m3', 1410, 0, 0.000710, '2026-11-22T11:56:00+00'),
('70000000-0000-4000-8000-000000000023', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000002', 'd0000000-0000-4000-8000-000000000004',
 'e0000000-0000-4000-8000-000000000022', 'embedding', 'bge-m3', 172, 0, 0.000090, '2026-11-22T12:12:00+00'),
('70000000-0000-4000-8000-000000000024', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'd0000000-0000-4000-8000-000000000011',
 'e0000000-0000-4000-8000-000000000023', 'embedding', 'bge-m3', 690, 0, 0.000350, '2026-11-22T12:13:00+00'),
('70000000-0000-4000-8000-000000000025', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002',
 'e0000000-0000-4000-8000-000000000021', 'embedding', 'bge-m3', 312, 0, 0.000160, '2026-11-22T11:58:00+00'),
('70000000-0000-4000-8000-000000000026', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000002', 'd0000000-0000-4000-8000-000000000004',
 'e0000000-0000-4000-8000-000000000022', 'embedding', 'bge-m3', 141, 0, 0.000070, '2026-11-22T12:14:00+00'),
-- ue27: local TEI (the A/B challenger) spend — cost NULL (local class,
-- I01 DR-14 fixture pattern); the model column echoes the registry wire name
('70000000-0000-4000-8000-000000000027', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002',
 'e0000000-0000-4000-8000-000000000021', 'embedding', 'sentence-transformers/all-MiniLM-L6-v2',
 1410, 0, NULL, '2026-11-22T12:33:00+00'),
('70000000-0000-4000-8000-000000000028', '00000000-0000-4000-8000-000000000002',
 'b0000000-0000-4000-8000-000000000003', 'd0000000-0000-4000-8000-000000000003',
 'e0000000-0000-4000-8000-000000000024', 'embedding', 'bge-m3', 205, 0, 0.000100, '2026-11-22T09:22:00+00'),
('70000000-0000-4000-8000-000000000029', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'd0000000-0000-4000-8000-000000000011',
 'e0000000-0000-4000-8000-000000000023', 'embedding', 'bge-m3', 131, 0, 0.000070, '2026-11-22T12:15:00+00');

-- ---------------------------------------------------------------------------
-- 4. embed_jobs — the pipeline ledger (R-031). 17 rows: every lifecycle
--    state present; an idem-RETRY pair (j08 failed -> j07 complete share an
--    idem key — uq_embed_jobs_idem_active excludes failed rows); a re-embed
--    generation RUNNING mid-flight (j06: done 2 of 4 — the resumable
--    cursor); fetch/chunk jobs for the pipeline head.
-- ---------------------------------------------------------------------------
INSERT INTO embed_jobs
  (id, user_id, quest_id, phase_id, kind, model_id, target_kind, strategy_id,
   source_id, state, idem_key, total_items, done_items,
   started_at, ended_at, error_note, usage_event_id) VALUES
-- fetch head (web-call budget, not token spend: no usage row by design)
('91000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001',
 'fetch', NULL, NULL, NULL, 'a0000000-0000-4000-8000-000000000001',
 'complete', 'fetch:src:a0000000-0000-4000-8000-000000000001', 1, 1,
 '2026-11-22T10:00:00+00', '2026-11-22T10:01:00+00', NULL, NULL),
('91000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001',
 'fetch', NULL, NULL, NULL, 'a0000000-0000-4000-8000-000000000007',
 'complete', 'fetch:src:a0000000-0000-4000-8000-000000000007', 1, 1,
 '2026-11-22T16:00:00+00', '2026-11-22T16:02:00+00', NULL, NULL),
-- chunk head: para-800 generation over quest A's staged citable corpus (17
-- chunks exist from it); para-400 over the agenda note (4)
('91000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001',
 'chunk', NULL, NULL, 'c0000000-0000-4000-8000-000000000001', NULL,
 'complete', 'chunk:c0000000-0000-4000-8000-000000000001:quest:b0000000-0000-4000-8000-000000000001', 17, 17,
 '2026-11-22T10:10:00+00', '2026-11-22T10:30:00+00', NULL, NULL),
('91000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001',
 'chunk', NULL, NULL, 'c0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000005',
 'complete', 'chunk:c0000000-0000-4000-8000-000000000002:src:a0000000-0000-4000-8000-000000000005', 4, 4,
 '2026-11-22T10:31:00+00', '2026-11-22T10:35:00+00', NULL, NULL),
-- embed: chunks para-800 complete; para-400 RUNNING (resumable cursor 2/4)
('91000000-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002',
 'embed', '92000000-0000-4000-8000-000000000001', 'chunk', 'c0000000-0000-4000-8000-000000000001', NULL,
 'complete', 'embed:92000000-0000-4000-8000-000000000001:chunk:c0000000-0000-4000-8000-000000000001', 17, 17,
 '2026-11-22T11:46:00+00', '2026-11-22T11:52:00+00', NULL,
 '70000000-0000-4000-8000-000000000021'),
('91000000-0000-4000-8000-000000000006', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002',
 'embed', '92000000-0000-4000-8000-000000000001', 'chunk', 'c0000000-0000-4000-8000-000000000002', NULL,
 'running', 'embed:92000000-0000-4000-8000-000000000001:chunk:c0000000-0000-4000-8000-000000000002', 4, 2,
 '2026-11-22T11:53:00+00', NULL, NULL, NULL),
-- embed: claims per quest (complete) + the failed first attempt sharing j07's idem
('91000000-0000-4000-8000-000000000007', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002',
 'embed', '92000000-0000-4000-8000-000000000001', 'claim', NULL, NULL,
 'complete', 'embed:92000000-0000-4000-8000-000000000001:claim:quest:b0000000-0000-4000-8000-000000000001', 8, 8,
 '2026-11-22T11:54:00+00', '2026-11-22T11:56:00+00', NULL,
 '70000000-0000-4000-8000-000000000022'),
('91000000-0000-4000-8000-000000000008', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002',
 'embed', '92000000-0000-4000-8000-000000000001', 'claim', NULL, NULL,
 'failed', 'embed:92000000-0000-4000-8000-000000000001:claim:quest:b0000000-0000-4000-8000-000000000001', 8, 2,
 '2026-11-22T11:20:00+00', '2026-11-22T11:31:00+00',
 'provider 429 rate limit after two batches; partial rows rolled back and retried as job 91000000-0000-4000-8000-000000000007', NULL),
('91000000-0000-4000-8000-000000000009', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000002', 'd0000000-0000-4000-8000-000000000004',
 'embed', '92000000-0000-4000-8000-000000000001', 'claim', NULL, NULL,
 'complete', 'embed:92000000-0000-4000-8000-000000000001:claim:quest:b0000000-0000-4000-8000-000000000002', 1, 1,
 '2026-11-22T12:11:00+00', '2026-11-22T12:12:00+00', NULL,
 '70000000-0000-4000-8000-000000000023'),
('91000000-0000-4000-8000-000000000010', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'd0000000-0000-4000-8000-000000000011',
 'embed', '92000000-0000-4000-8000-000000000001', 'claim', NULL, NULL,
 'complete', 'embed:92000000-0000-4000-8000-000000000001:claim:quest:b0000000-0000-4000-8000-000000000010', 4, 4,
 '2026-11-22T12:11:00+00', '2026-11-22T12:13:00+00', NULL,
 '70000000-0000-4000-8000-000000000024'),
-- embed: frontier needs per quest (embed-at-add; closed history retained)
('91000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002',
 'embed', '92000000-0000-4000-8000-000000000001', 'frontier_need', NULL, NULL,
 'complete', 'embed:92000000-0000-4000-8000-000000000001:need:quest:b0000000-0000-4000-8000-000000000001', 4, 4,
 '2026-11-22T11:57:00+00', '2026-11-22T11:58:00+00', NULL,
 '70000000-0000-4000-8000-000000000025'),
('91000000-0000-4000-8000-000000000012', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000002', 'd0000000-0000-4000-8000-000000000004',
 'embed', '92000000-0000-4000-8000-000000000001', 'frontier_need', NULL, NULL,
 'complete', 'embed:92000000-0000-4000-8000-000000000001:need:quest:b0000000-0000-4000-8000-000000002', 1, 1,
 '2026-11-22T12:13:00+00', '2026-11-22T12:14:00+00', NULL,
 '70000000-0000-4000-8000-000000000026'),
('91000000-0000-4000-8000-000000000017', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000010', 'd0000000-0000-4000-8000-000000000011',
 'embed', '92000000-0000-4000-8000-000000000001', 'frontier_need', NULL, NULL,
 'complete', 'embed:92000000-0000-4000-8000-000000000001:need:quest:b0000000-0000-4000-8000-000000000010', 1, 1,
 '2026-11-22T12:14:00+00', '2026-11-22T12:15:00+00', NULL,
 '70000000-0000-4000-8000-000000000029'),
-- A/B challenger: claims quest A complete (local TEI, cost-NULL spend);
-- needs quest A still PENDING (queued — the A/B leg not yet run)
('91000000-0000-4000-8000-000000000013', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002',
 'embed', '92000000-0000-4000-8000-000000000002', 'claim', NULL, NULL,
 'complete', 'embed:92000000-0000-4000-8000-000000000002:claim:quest:b0000000-0000-4000-8000-000000000001', 8, 8,
 '2026-11-22T12:30:00+00', '2026-11-22T12:33:00+00', NULL,
 '70000000-0000-4000-8000-000000000027'),
('91000000-0000-4000-8000-000000000014', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002',
 'embed', '92000000-0000-4000-8000-000000000002', 'frontier_need', NULL, NULL,
 'pending', 'embed:92000000-0000-4000-8000-000000000002:need:quest:b0000000-0000-4000-8000-000000000001', 4, 0,
 NULL, NULL, NULL, NULL),
-- retired model's failed backfill (the retire story: m3 died mid-flight,
-- was retired; failed jobs don't pin 'active' against the flip — uq and FK
-- semantics allow exactly this ending)
('91000000-0000-4000-8000-000000000015', '00000000-0000-4000-8000-000000000001',
 'b0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001',
 'embed', '92000000-0000-4000-8000-000000000003', 'claim', NULL, NULL,
 'failed', 'embed:92000000-0000-4000-8000-000000000003:claim:quest:b0000000-0000-4000-8000-000000000001', 8, 0,
 '2026-11-22T09:40:00+00', '2026-11-22T09:52:00+00',
 'model decommissioned by provider mid-backfill; retired instead of retried', NULL),
-- tenant B's own embed job (bob, quest C) — per-user cost chain complete
('91000000-0000-4000-8000-000000000016', '00000000-0000-4000-8000-000000000002',
 'b0000000-0000-4000-8000-000000000003', 'd0000000-0000-4000-8000-000000000003',
 'embed', '92000000-0000-4000-8000-000000000001', 'claim', NULL, NULL,
 'complete', 'embed:92000000-0000-4000-8000-000000000001:claim:quest:b0000000-0000-4000-8000-000000000003', 1, 1,
 '2026-11-22T09:21:00+00', '2026-11-22T09:22:00+00', NULL,
 '70000000-0000-4000-8000-000000000028');

-- ---------------------------------------------------------------------------
-- 5. vectors. Deterministic synth_vec(text, dims); embedded_text captures
--    the exact wire input (chunk text / claim canonical_text / need text —
--    the DR-05 target set; evidence readings deliberately absent).
--    Note j06 (running) contributes exactly its done_items = 2 rows.
-- ---------------------------------------------------------------------------
INSERT INTO emb_bge_m3_1024
  (model_id, model_status, user_id, target_kind, chunk_id, embedding, embedded_text, job_id)
SELECT '92000000-0000-4000-8000-000000000001', 'active', c.user_id, 'chunk', c.id,
       pg_temp.synth_vec(c.text, 1024), c.text,
       CASE cs.name WHEN 'para-800' THEN '91000000-0000-4000-8000-000000000005'::uuid
                    ELSE '91000000-0000-4000-8000-000000000006'::uuid END
FROM chunks c
JOIN chunk_strategies cs ON cs.id = c.strategy_id
WHERE cs.name = 'para-800'
   OR (cs.name = 'para-400' AND c.ordinal <= 2);

INSERT INTO emb_bge_m3_1024
  (model_id, model_status, user_id, target_kind, claim_id, embedding, embedded_text, job_id)
SELECT '92000000-0000-4000-8000-000000000001', 'active', c.user_id, 'claim', c.id,
       pg_temp.synth_vec(c.canonical_text, 1024), c.canonical_text,
       CASE c.quest_id
         WHEN 'b0000000-0000-4000-8000-000000000001' THEN '91000000-0000-4000-8000-000000000007'::uuid
         WHEN 'b0000000-0000-4000-8000-000000000002' THEN '91000000-0000-4000-8000-000000000009'::uuid
         WHEN 'b0000000-0000-4000-8000-000000000010' THEN '91000000-0000-4000-8000-000000000010'::uuid
         ELSE '91000000-0000-4000-8000-000000000016'::uuid END
FROM claims c;

INSERT INTO emb_bge_m3_1024
  (model_id, model_status, user_id, target_kind, need_id, embedding, embedded_text, job_id)
SELECT '92000000-0000-4000-8000-000000000001', 'active', f.user_id, 'frontier_need', f.id,
       pg_temp.synth_vec(f.need, 1024), f.need,
       CASE f.quest_id
         WHEN 'b0000000-0000-4000-8000-000000000001' THEN '91000000-0000-4000-8000-000000000011'::uuid
         WHEN 'b0000000-0000-4000-8000-000000000002' THEN '91000000-0000-4000-8000-000000000012'::uuid
         ELSE '91000000-0000-4000-8000-000000000017'::uuid END
FROM frontier_entries f;

INSERT INTO emb_minilm_ab_384
  (model_id, model_status, user_id, target_kind, claim_id, embedding, embedded_text, job_id)
SELECT '92000000-0000-4000-8000-000000000002', 'active', c.user_id, 'claim', c.id,
       pg_temp.synth_vec(c.canonical_text, 384), c.canonical_text,
       '91000000-0000-4000-8000-000000000013'::uuid
FROM claims c
WHERE c.quest_id = 'b0000000-0000-4000-8000-000000000001';

-- ============================================================================
-- SELF-VERIFICATION (temp-table assert idiom; the ALTER at the end fails
-- the load on any nonzero count)
-- ============================================================================
INSERT INTO seed_asserts (check_name, violations) VALUES
-- registry minimums (R-028): two active (A/B posture) + one retired
('registry_three_models_two_active', (
  SELECT abs(count(*) - 3) + abs(count(*) FILTER (WHERE status = 'active') - 2)
  FROM embedding_models)),
('registry_retire_pair_holds', (
  SELECT count(*) FROM embedding_models
  WHERE (status = 'retired') <> (retired_at IS NOT NULL))),
('registry_retired_table_absent', (
  SELECT count(*) FROM embedding_models
  WHERE status = 'retired' AND to_regclass(table_name) IS NOT NULL)),
-- every vector re-derives byte-identically from its embedded_text (the
-- determinism claim of DR-15, proven, not asserted in prose)
('vectors_deterministic_1024', (
  SELECT count(*) FROM emb_bge_m3_1024
  WHERE embedding <=> pg_temp.synth_vec(embedded_text, 1024) <> 0)),
('vectors_deterministic_384', (
  SELECT count(*) FROM emb_minilm_ab_384
  WHERE embedding <=> pg_temp.synth_vec(embedded_text, 384) <> 0)),
-- no zero/NaN vectors (every embedded text carried >=1 content token)
('vectors_nonzero_1024', (
  SELECT count(*) FROM emb_bge_m3_1024
  WHERE embedding <=> embedding <> 0 OR embedding <=> embedding IS NULL)),
('vectors_nonzero_384', (
  SELECT count(*) FROM emb_minilm_ab_384
  WHERE embedding <=> embedding <> 0 OR embedding <=> embedding IS NULL)),
-- rebuild law (L10): embedded_text byte-matches the target's CURRENT text
('embedded_text_matches_target', (
  (SELECT count(*) FROM emb_bge_m3_1024 e JOIN chunks c ON c.id = e.chunk_id
     WHERE e.embedded_text <> c.text)
  + (SELECT count(*) FROM emb_bge_m3_1024 e JOIN claims c ON c.id = e.claim_id
       WHERE e.embedded_text <> c.canonical_text)
  + (SELECT count(*) FROM emb_bge_m3_1024 e JOIN frontier_entries f ON f.id = e.need_id
       WHERE e.embedded_text <> f.need)
  + (SELECT count(*) FROM emb_minilm_ab_384 e JOIN claims c ON c.id = e.claim_id
       WHERE e.embedded_text <> c.canonical_text))),
-- evidence readings are NOT an embedding target (DR-05): no target kind
-- names them (CHECK enforces the enum; assert the corpus holds none anyway)
('no_evidence_reading_targets', (
  SELECT count(*) FROM emb_bge_m3_1024 WHERE target_kind NOT IN
    ('chunk', 'claim', 'frontier_need'))),
-- job coherence: vectors pin their job's model; running job's rows equal
-- its done cursor; complete jobs reached their totals
('vectors_pin_job_model', (
  (SELECT count(*) FROM emb_bge_m3_1024 e JOIN embed_jobs j ON j.id = e.job_id
     WHERE e.model_id <> j.model_id)
  + (SELECT count(*) FROM emb_minilm_ab_384 e JOIN embed_jobs j ON j.id = e.job_id
     WHERE e.model_id <> j.model_id))),
('running_job_rows_match_cursor', (
  SELECT abs((SELECT count(*) FROM emb_bge_m3_1024
               WHERE job_id = '91000000-0000-4000-8000-000000000006')
             - (SELECT done_items FROM embed_jobs
                 WHERE id = '91000000-0000-4000-8000-000000000006')))),
('complete_jobs_done_equals_total', (
  SELECT count(*) FROM embed_jobs
  WHERE state = 'complete' AND done_items <> total_items)),
-- cost accounting (D10): every COMPLETE embed job carries a usage row of
-- kind 'embedding', same user, same quest; no other job does
('spend_links_complete_embed_jobs_only', (
  SELECT count(*) FROM embed_jobs j
  WHERE ((j.kind = 'embed' AND j.state = 'complete') <> (j.usage_event_id IS NOT NULL))
     OR (j.usage_event_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM usage_events u
       WHERE u.id = j.usage_event_id AND u.user_id = j.user_id
         AND u.kind = 'embedding' AND u.quest_id = j.quest_id)))),
-- idempotency shape: exactly one non-failed row per idem key; the seeded
-- retry pair shares its key legally
('idem_one_live_row_per_key', (
  SELECT count(*) FROM (
    SELECT idem_key FROM embed_jobs WHERE state <> 'failed'
    GROUP BY idem_key HAVING count(*) > 1) d)),
('idem_retry_pair_seeded', (
  SELECT abs(count(*) - 1) FROM (
    SELECT idem_key FROM embed_jobs
    WHERE idem_key = 'embed:92000000-0000-4000-8000-000000000001:claim:quest:b0000000-0000-4000-8000-000000000001'
    GROUP BY idem_key HAVING count(*) FILTER (WHERE state = 'failed') = 1
       AND count(*) FILTER (WHERE state = 'complete') = 1) d)),
-- every lifecycle state present (R-031 fixture contract)
('jobs_every_lifecycle_state', (
  SELECT abs(count(*) - 4) FROM (
    SELECT DISTINCT state FROM embed_jobs) d)),
-- target families all populated in the fixture model (DR-05)
('targets_all_families_populated', (
  SELECT abs(count(*) - 3) FROM (
    SELECT DISTINCT target_kind FROM emb_bge_m3_1024 WHERE target_kind IS NOT NULL) d)),
-- FTS substrate live: every chunk carries lexemes
('chunks_have_fts_lexemes', (
  SELECT count(*) FROM chunks WHERE search_tsv IS NULL OR search_tsv = ''::tsvector));

SELECT * FROM seed_asserts ORDER BY check_name;
ALTER TABLE seed_asserts ADD CONSTRAINT ck_seed_i03_asserts_all_zero CHECK (violations = 0);

-- fixture counts (informational)
SELECT 'embedding_models' AS what, count(*) AS n FROM embedding_models
UNION ALL SELECT 'embed_jobs',          count(*) FROM embed_jobs
UNION ALL SELECT 'emb_bge_m3_1024',     count(*) FROM emb_bge_m3_1024
UNION ALL SELECT 'emb_minilm_ab_384',   count(*) FROM emb_minilm_ab_384
UNION ALL SELECT '  chunk vectors',     count(*) FROM emb_bge_m3_1024 WHERE target_kind = 'chunk'
UNION ALL SELECT '  claim vectors',     count(*) FROM emb_bge_m3_1024 WHERE target_kind = 'claim'
UNION ALL SELECT '  need vectors',      count(*) FROM emb_bge_m3_1024 WHERE target_kind = 'frontier_need'
UNION ALL SELECT 'embedding usage rows', count(*) FROM usage_events WHERE kind = 'embedding';

DROP TABLE seed_asserts;

COMMIT;
