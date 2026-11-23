-- ============================================================================
-- kquest I07 assurance — THE executable tripwire catalog (tripwires-i07.sql)
-- ----------------------------------------------------------------------------
-- R-069 (catalog §G): the tripwire catalog as EXECUTABLE SQL PREDICATES over
-- the I01 tables (sessions, tool_calls, usage_events, phases, frontier
-- entries) + the I02 views where needed (v_canonical_claims for hub type
-- divergence; v_quest_graph_fingerprint for report/archive pin drift).
--
-- Prerequisites (applied by check-tripwires.sh in this order):
--   1. design/I01-core-model/artifacts/schema.sql   (frozen law)
--   2. design/I01-core-model/artifacts/seed.sql
--   3. design/I02-cross-quest/artifacts/schema-i02.sql (frozen law)
--   4. design/I02-cross-quest/artifacts/seed-i02.sql
--
-- LAW (I06 owns the transition law; I04 owns the failure-mode handling):
--   - Tripwires DETECT and SIGNAL. They never transition phases and they
--     never auto-kill (FM-18: NEVER auto-kill on growth alone; FM-17: a
--     budget stop is never silently reportless). Signals are alert-class
--     events on the ENTRY 8 SSE quest-watch stream (slot: assurance_alert).
--   - A tripwire that fires on clean data is a DEFECT. Every predicate below
--     carries a seeded FIRING fixture AND a clean counter-case; the
--     self-verification block asserts fire AND quiet, scoped to the fixture
--     tenant (global counts may include prior-law seed data — the views are
--     production-global by design).
--
-- THRESHOLD PROVENANCE (parity-checked by check-coverage.sh against I06
-- stop-rules.tsv — shared values must match exactly or a DECISIONS record
-- amends them; this file amends nothing):
--   SR-08  phase retry cap ..................... default 3
--   SR-15  engine.transcript_ceiling_warn_bytes  default 450000
--   SR-16  engine.transcript_ceiling_hard_bytes  default 496000
--   SR-17  engine.slow_stall_bytes ............. default 100
--   SR-18  engine.slow_stall_window_s .......... default 1200
--   SR-19  engine.unattended_pause_s ........... default 3600
-- Non-SR thresholds cite their own provenance per predicate (I04 FM rows /
-- PoC arc notes).
--
-- DURABLE-LEDGER HONESTY NOTE (DECISIONS DR-07): the PoC babysitter's
-- byte-level signals (SLOWSTALL file growth, SIZE-CEILING file size) read
-- the LIVE transcript file. The transcript blob lives in object storage,
-- not PG; the relational catalog expresses the DURABLE PROJECTION of each
-- signal over the verbatim audit ledger (tool_calls args/result bytes ARE
-- transcript bytes — L8). Where the projection is one-sided (durable audit
-- bytes are a LOWER BOUND of live transcript bytes), the predicate says so
-- and the byte-accurate live forms ride the ENTRY 8 watcher with the SAME
-- SR-17/18 keys.
--
-- Idempotent: fixed fixture UUIDs + ON CONFLICT (id) DO NOTHING; views are
-- CREATE OR REPLACE. plpgsql-free (assert = temp table + CHECK, I01 idiom).
-- ============================================================================

BEGIN;

-- fixture anchors (fixed ids; prefix 77=quests, 78=phases, 79=sessions,
-- 7a=tool_calls, 7b=usage_events, 7c=claims, 7e=report/archive pins)
\set U9 '00000000-0000-4000-8000-000000000009'
\set Q1 '77000000-0000-4000-8000-000000000001'
\set Q2 '77000000-0000-4000-8000-000000000002'
\set Q3 '77000000-0000-4000-8000-000000000003'
\set Q4 '77000000-0000-4000-8000-000000000004'
\set Q5 '77000000-0000-4000-8000-000000000005'
\set Q6 '77000000-0000-4000-8000-000000000006'
\set Q7 '77000000-0000-4000-8000-000000000007'
\set P_DES1  '78000000-0000-4000-8000-000000000001'
\set P_DES3  '78000000-0000-4000-8000-000000000003'
\set P_SYN3  '78000000-0000-4000-8000-000000000013'
\set P_ROT4  '78000000-0000-4000-8000-000000000004'
\set P_ROT4A1 '78000000-0000-4000-8000-000000000014'
\set P_ROT4A2 '78000000-0000-4000-8000-000000000015'
\set P_ROT4A3 '78000000-0000-4000-8000-000000000016'
\set P_DES5  '78000000-0000-4000-8000-000000000005'
\set P_DES6  '78000000-0000-4000-8000-000000000006'
\set P_VER7  '78000000-0000-4000-8000-000000000007'
\set S_CEIL   '79000000-0000-4000-8000-000000000001'
\set S_CHURN  '79000000-0000-4000-8000-000000000002'
\set S_REPLAY '79000000-0000-4000-8000-000000000003'
\set S_EMPTY  '79000000-0000-4000-8000-000000000004'
\set S_NOSPEND '79000000-0000-4000-8000-000000000005'
\set S_CACHE  '79000000-0000-4000-8000-000000000006'
\set S_SHAPE  '79000000-0000-4000-8000-000000000007'
\set S_SMALL  '79000000-0000-4000-8000-000000000008'
\set S_WEDGE  '79000000-0000-4000-8000-000000000009'
\set S_TRICK  '79000000-0000-4000-8000-000000000010'
\set S_OK     '79000000-0000-4000-8000-000000000011'
\set S_SYN    '79000000-0000-4000-8000-000000000012'
\set RV1 '7e000000-0000-4000-8000-000000000001'
\set RV2 '7e000000-0000-4000-8000-000000000002'
\set ARC7 '7e000000-0000-4000-8000-000000000011'
\set Q8     '78000000-0000-4000-8000-000000000008'
\set P_DES8 '7d000000-0000-4000-8000-000000000008'
\set P_DES9 '7d000000-0000-4000-8000-000000000009'
\set S_NEAR '79000000-0000-4000-8000-000000000013'
\set S_BLOW '79000000-0000-4000-8000-000000000014'

-- ============================================================================
-- PART A — FIXTURES (idempotent: ON CONFLICT (id) DO NOTHING everywhere)
-- ----------------------------------------------------------------------------
-- One dedicated tenant (U9, handle 'tw-fix') so every fire/quiet assert is
-- scoped and immune to prior-law seed data. Quest map:
--   Q1 ended-session zoo   : ceiling-band, churn, empty-storm, replay,
--                            missing-spend, cache-wall, shape-storm, clean
--   Q2 divergence quest A  : claims typed primary-empirical
--   Q3 fingerprint quest   : claims + synthesis + report pins + mutation
--   Q4 wedge/rotation quest: live frozen session in a beyond-cap attempt
--   Q5 trickle quest       : live slowstall session
--   Q6 clean live quest    : the all-quiet counter-case
--   Q7 archive quest       : pinned archive + post-archive rework (drift)
--   Q8 near-miss + blowout : the count-axis NEAR-MISS quiet fixtures
--                            (judge F3) + the FM-22 context-blowout storm
--                            (judge F1)
-- ============================================================================

INSERT INTO users (id, handle, display_name) VALUES
  (:'U9', 'tw-fix', 'Assurance Fixture Tenant')
ON CONFLICT (id) DO NOTHING;

INSERT INTO quests (id, user_id, topic, state, provenance_kind, source_quest_id,
                    web_call_budget, token_budget, spend_budget_usd) VALUES
  (:'Q1', :'U9', 'Assurance fixture quest 1: ended-session signal zoo', 'complete', 'fresh', NULL, 300, 1000000, 10.0000),
  (:'Q2', :'U9', 'Assurance fixture quest 2: hub divergence side A', 'active', 'fresh', NULL, 300, 1000000, 10.0000),
  (:'Q3', :'U9', 'Assurance fixture quest 3: report pin drift', 'complete', 'fresh', NULL, 300, 1000000, 10.0000),
  (:'Q4', :'U9', 'Assurance fixture quest 4: wedge in a rotated phase', 'active', 'fresh', NULL, 300, 1000000, 10.0000),
  (:'Q5', :'U9', 'Assurance fixture quest 5: slow trickle under a local model', 'active', 'fresh', NULL, 300, 1000000, 10.0000),
  (:'Q6', :'U9', 'Assurance fixture quest 6: the clean live counter-case', 'active', 'fresh', NULL, 300, 1000000, 10.0000),
  (:'Q7', :'U9', 'Assurance fixture quest 7: archive pin then rework', 'archived', 'fresh', NULL, 300, 1000000, 10.0000),
  (:'Q8', :'U9', 'Assurance fixture quest 8: near-miss counter-cases + the FM-22 blowout', 'active', 'fresh', NULL, 300, 1000000, 10.0000)
ON CONFLICT (id) DO NOTHING;

INSERT INTO phases (id, user_id, quest_id, kind, round_no, attempt_no, state,
                    started_at, ended_at) VALUES
  (:'P_DES1', :'U9', :'Q1', 'decompose', 1, 1, 'complete', now() - interval '4 hours', now() - interval '1 hour'),
  (:'P_DES3', :'U9', :'Q3', 'decompose', 1, 1, 'complete', now() - interval '2 hours', now() - interval '90 minutes'),
  (:'P_SYN3', :'U9', :'Q3', 'synthesis',  1, 1, 'complete', now() - interval '80 minutes', now() - interval '55 minutes'),
  (:'P_ROT4A1', :'U9', :'Q4', 'descent', 1, 1, 'failed', now() - interval '6 hours', now() - interval '5 hours 30 minutes'),
  (:'P_ROT4A2', :'U9', :'Q4', 'descent', 1, 2, 'failed', now() - interval '5 hours 30 minutes', now() - interval '5 hours'),
  (:'P_ROT4A3', :'U9', :'Q4', 'descent', 1, 3, 'failed', now() - interval '5 hours', now() - interval '4 hours 30 minutes'),
  (:'P_ROT4',  :'U9', :'Q4', 'descent', 1, 4, 'running', now() - interval '4 hours', NULL),
  (:'P_DES5', :'U9', :'Q5', 'descent', 1, 1, 'running', now() - interval '40 minutes', NULL),
  (:'P_DES6', :'U9', :'Q6', 'descent', 1, 1, 'running', now() - interval '40 minutes', NULL),
  (:'P_VER7', :'U9', :'Q7', 'verification', 1, 1, 'complete', now() - interval '3 hours', now() - interval '2 hours'),
  (:'P_DES8', :'U9', :'Q8', 'decompose', 1, 1, 'running', now() - interval '30 minutes', NULL),
  (:'P_DES9', :'U9', :'Q8', 'decompose', 2, 1, 'running', now() - interval '25 minutes', NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO sessions (id, user_id, quest_id, phase_id, mode, driver, model,
                      transcript_blob_key, started_at, ended_at) VALUES
  -- Q1: the ended-session zoo (one phase attempt, many cold-boot sessions)
  (:'S_CEIL',   :'U9', :'Q1', :'P_DES1', 'autonomous', 'orchestrator', 'glm-5.3',
   'sessions/79000000-0000-4000-8000-000000000001/transcript.jsonl', now() - interval '3 hours', now() - interval '2 hours'),
  (:'S_CHURN',  :'U9', :'Q1', :'P_DES1', 'autonomous', 'orchestrator', 'glm-5.3',
   'sessions/79000000-0000-4000-8000-000000000002/transcript.jsonl', now() - interval '3 hours', now() - interval '2 hours'),
  (:'S_REPLAY', :'U9', :'Q1', :'P_DES1', 'autonomous', 'orchestrator', 'glm-5.3',
   'sessions/79000000-0000-4000-8000-000000000003/transcript.jsonl', now() - interval '3 hours', now() - interval '2 hours'),
  (:'S_EMPTY',  :'U9', :'Q1', :'P_DES1', 'autonomous', 'orchestrator', 'tf-qwen3.8-flash-next-4bit',
   'sessions/79000000-0000-4000-8000-000000000004/transcript.jsonl', now() - interval '3 hours', now() - interval '2 hours'),
  (:'S_NOSPEND', :'U9', :'Q1', :'P_DES1', 'autonomous', 'orchestrator', 'glm-5.3',
   'sessions/79000000-0000-4000-8000-000000000005/transcript.jsonl', now() - interval '3 hours', now() - interval '2 hours'),
  (:'S_CACHE',  :'U9', :'Q1', :'P_DES1', 'autonomous', 'orchestrator', 'tf-qwen3.8-flash-next-4bit',
   'sessions/79000000-0000-4000-8000-000000000006/transcript.jsonl', now() - interval '3 hours', now() - interval '2 hours'),
  (:'S_SHAPE',  :'U9', :'Q1', :'P_DES1', 'autonomous', 'orchestrator', 'glm-5.3',
   'sessions/79000000-0000-4000-8000-000000000007/transcript.jsonl', now() - interval '3 hours', now() - interval '2 hours'),
  (:'S_SMALL',  :'U9', :'Q1', :'P_DES1', 'autonomous', 'orchestrator', 'glm-5.3',
   'sessions/79000000-0000-4000-8000-000000000008/transcript.jsonl', now() - interval '3 hours', now() - interval '2 hours'),
  -- Q3: the report-writing session (ended)
  (:'S_SYN',    :'U9', :'Q3', :'P_SYN3', 'autonomous', 'orchestrator', 'glm-5.3',
   'sessions/79000000-0000-4000-8000-000000000012/transcript.jsonl', now() - interval '80 minutes', now() - interval '55 minutes'),
  -- Q4: the WEDGE fixture — live, frozen past the stall window
  (:'S_WEDGE',  :'U9', :'Q4', :'P_ROT4', 'autonomous', 'orchestrator', 'glm-5.3',
   'sessions/79000000-0000-4000-8000-000000000009/transcript.jsonl', now() - interval '2 hours', NULL),
  -- Q5: the SLOWSTALL trickle fixture — live, events flowing, bytes trickling
  (:'S_TRICK',  :'U9', :'Q5', :'P_DES5', 'autonomous', 'orchestrator', 'tf-qwen3.8-flash-next-4bit',
   'sessions/79000000-0000-4000-8000-000000000010/transcript.jsonl', now() - interval '25 minutes', NULL),
  -- Q6: the CLEAN live counter-case — fresh events, healthy payload
  (:'S_OK',     :'U9', :'Q6', :'P_DES6', 'interactive', 'operator', 'glm-5.3',
   'sessions/79000000-0000-4000-8000-000000000011/transcript.jsonl', now() - interval '10 minutes', NULL),
  -- Q8/S_NEAR: the NEAR-MISS counter-case (judge F3) — every count axis
  -- sits exactly ONE under its storm threshold
  (:'S_NEAR',   :'U9', :'Q8', :'P_DES8', 'autonomous', 'orchestrator', 'glm-5.3',
   'sessions/79000000-0000-4000-8000-000000000013/transcript.jsonl', now() - interval '30 minutes', NULL),
  -- Q8/S_BLOW: the FM-22 CONTEXT-BLOWOUT storm (judge F1) — the
  -- non-sliced-read teaching refusal ignored three times in a row
  (:'S_BLOW',   :'U9', :'Q8', :'P_DES9', 'autonomous', 'orchestrator', 'glm-5.3',
   'sessions/79000000-0000-4000-8000-000000000014/transcript.jsonl', now() - interval '25 minutes', NULL)
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- tool_calls fixtures (the L8 verbatim audit ledger; payload = args+result
-- bytes IS transcript bytes, the durable lower bound)
-- ---------------------------------------------------------------------------
INSERT INTO tool_calls (id, user_id, quest_id, session_id, seq, tool, op, args, result, ok, error_class, created_at) VALUES
  -- S_CEIL: the ceiling-band transcript fixture — 5 x ~91 KB verbatim audit
  -- rows ~= 455 KB durable payload: in the SR-15 warn band, below SR-16 hard
  ('7a000000-0000-4000-8000-000000000001', :'U9', :'Q1', :'S_CEIL', 1, 'web', 'fetch_save',
   '{"url":"https://fixture.example/ceiling-transcript-part-1"}'::jsonb,
   to_jsonb(repeat('c', 91000)), true, NULL, now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000002', :'U9', :'Q1', :'S_CEIL', 2, 'web', 'fetch_save',
   '{"url":"https://fixture.example/ceiling-transcript-part-2"}'::jsonb,
   to_jsonb(repeat('c', 91000)), true, NULL, now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000003', :'U9', :'Q1', :'S_CEIL', 3, 'web', 'fetch_save',
   '{"url":"https://fixture.example/ceiling-transcript-part-3"}'::jsonb,
   to_jsonb(repeat('c', 91000)), true, NULL, now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000004', :'U9', :'Q1', :'S_CEIL', 4, 'web', 'fetch_save',
   '{"url":"https://fixture.example/ceiling-transcript-part-4"}'::jsonb,
   to_jsonb(repeat('c', 91000)), true, NULL, now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000005', :'U9', :'Q1', :'S_CEIL', 5, 'web', 'fetch_save',
   '{"url":"https://fixture.example/ceiling-transcript-part-5"}'::jsonb,
   to_jsonb(repeat('c', 91000)), true, NULL, now() - interval '3 hours'),
  -- S_CHURN: the churn fixture — 10 consecutive refused calls, varied args
  ('7a000000-0000-4000-8000-000000000011', :'U9', :'Q1', :'S_CHURN', 1, 'graph', 'node_add',
   '{"op":"node_add","attempt":1}'::jsonb,
   '{"error":"GRAPH_INVALID: fixture refusal"}'::jsonb, false, 'GRAPH_INVALID', now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000012', :'U9', :'Q1', :'S_CHURN', 2, 'graph', 'node_add',
   '{"op":"node_add","attempt":2}'::jsonb,
   '{"error":"GRAPH_INVALID: fixture refusal"}'::jsonb, false, 'GRAPH_INVALID', now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000013', :'U9', :'Q1', :'S_CHURN', 3, 'graph', 'node_add',
   '{"op":"node_add","attempt":3}'::jsonb,
   '{"error":"GRAPH_INVALID: fixture refusal"}'::jsonb, false, 'GRAPH_INVALID', now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000014', :'U9', :'Q1', :'S_CHURN', 4, 'graph', 'node_add',
   '{"op":"node_add","attempt":4}'::jsonb,
   '{"error":"GRAPH_INVALID: fixture refusal"}'::jsonb, false, 'GRAPH_INVALID', now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000015', :'U9', :'Q1', :'S_CHURN', 5, 'graph', 'node_add',
   '{"op":"node_add","attempt":5}'::jsonb,
   '{"error":"GRAPH_INVALID: fixture refusal"}'::jsonb, false, 'GRAPH_INVALID', now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000016', :'U9', :'Q1', :'S_CHURN', 6, 'graph', 'node_add',
   '{"op":"node_add","attempt":6}'::jsonb,
   '{"error":"GRAPH_INVALID: fixture refusal"}'::jsonb, false, 'GRAPH_INVALID', now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000017', :'U9', :'Q1', :'S_CHURN', 7, 'graph', 'node_add',
   '{"op":"node_add","attempt":7}'::jsonb,
   '{"error":"GRAPH_INVALID: fixture refusal"}'::jsonb, false, 'GRAPH_INVALID', now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000018', :'U9', :'Q1', :'S_CHURN', 8, 'graph', 'node_add',
   '{"op":"node_add","attempt":8}'::jsonb,
   '{"error":"GRAPH_INVALID: fixture refusal"}'::jsonb, false, 'GRAPH_INVALID', now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000019', :'U9', :'Q1', :'S_CHURN', 9, 'graph', 'node_add',
   '{"op":"node_add","attempt":9}'::jsonb,
   '{"error":"GRAPH_INVALID: fixture refusal"}'::jsonb, false, 'GRAPH_INVALID', now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000020', :'U9', :'Q1', :'S_CHURN', 10, 'graph', 'node_add',
   '{"op":"node_add","attempt":10}'::jsonb,
   '{"error":"GRAPH_INVALID: fixture refusal"}'::jsonb, false, 'GRAPH_INVALID', now() - interval '3 hours'),
  -- S_REPLAY: the repetition fixture — 3 byte-identical bodies (FM-03 loop:
  -- a failed call that does not mutate state produces an identical retry body)
  ('7a000000-0000-4000-8000-000000000021', :'U9', :'Q1', :'S_REPLAY', 1, 'graph', 'node_add',
   '{"op":"node_add","urn":"replay-fixture","retry_seed":0}'::jsonb,
   '{"error":"GRAPH_INVALID: fixture refusal"}'::jsonb, false, 'GRAPH_INVALID', now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000022', :'U9', :'Q1', :'S_REPLAY', 2, 'graph', 'node_add',
   '{"op":"node_add","urn":"replay-fixture","retry_seed":0}'::jsonb,
   '{"error":"GRAPH_INVALID: fixture refusal"}'::jsonb, false, 'GRAPH_INVALID', now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000023', :'U9', :'Q1', :'S_REPLAY', 3, 'graph', 'node_add',
   '{"op":"node_add","urn":"replay-fixture","retry_seed":0}'::jsonb,
   '{"error":"GRAPH_INVALID: fixture refusal"}'::jsonb, false, 'GRAPH_INVALID', now() - interval '3 hours'),
  -- S_EMPTY: the empty-completion-storm session's tool activity
  ('7a000000-0000-4000-8000-000000000031', :'U9', :'Q1', :'S_EMPTY', 1, 'graph', 'status',
   '{"op":"status"}'::jsonb,
   '{"claims":140,"evidence":198}'::jsonb, true, NULL, now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000032', :'U9', :'Q1', :'S_EMPTY', 2, 'graph', 'search',
   '{"q":"fixture empty storm probe"}'::jsonb,
   '{"hits":3}'::jsonb, true, NULL, now() - interval '3 hours'),
  -- S_NOSPEND: two successful calls, deliberately ZERO usage rows (FM-25)
  ('7a000000-0000-4000-8000-000000000041', :'U9', :'Q1', :'S_NOSPEND', 1, 'graph', 'status',
   '{"op":"status"}'::jsonb,
   '{"claims":141,"evidence":200}'::jsonb, true, NULL, now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000042', :'U9', :'Q1', :'S_NOSPEND', 2, 'graph', 'search',
   '{"q":"fixture no-spend probe"}'::jsonb,
   '{"hits":1}'::jsonb, true, NULL, now() - interval '3 hours'),
  -- S_CACHE: one routine call (the wall is in usage_events below)
  ('7a000000-0000-4000-8000-000000000051', :'U9', :'Q1', :'S_CACHE', 1, 'graph', 'status',
   '{"op":"status"}'::jsonb,
   '{"claims":142,"evidence":205}'::jsonb, true, NULL, now() - interval '3 hours'),
  -- S_SHAPE: 3 unknown-tool failures (an in-band teaching refusal pattern
  -- that has stopped self-correcting)
  ('7a000000-0000-4000-8000-000000000061', :'U9', :'Q1', :'S_SHAPE', 1, 'graph', 'status',
   '{"op":"status"}'::jsonb,
   '{"claims":143,"evidence":207}'::jsonb, true, NULL, now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000062', :'U9', :'Q1', :'S_SHAPE', 2, 'imaginary', 'probe',
   '{"what":"the model invented a tool"}'::jsonb,
   '{"error":"no such tool: imaginary"}'::jsonb, false, 'unknown_tool', now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000063', :'U9', :'Q1', :'S_SHAPE', 3, 'another1', 'probe',
   '{"what":"still inventing"}'::jsonb,
   '{"error":"no such tool: another1"}'::jsonb, false, 'unknown_tool', now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000064', :'U9', :'Q1', :'S_SHAPE', 4, 'another2', 'probe',
   '{"what":"and again"}'::jsonb,
   '{"error":"no such tool: another2"}'::jsonb, false, 'unknown_tool', now() - interval '3 hours'),
  -- S_SMALL: the clean ended counter-case — one legal transport-retry pair
  -- (identical args, fresh seed, FM-05) that must NOT trip tw_repetition
  ('7a000000-0000-4000-8000-000000000071', :'U9', :'Q1', :'S_SMALL', 1, 'web', 'search',
   '{"q":"fixture small retry probe"}'::jsonb,
   '{"error":"TIMEOUT"}'::jsonb, false, 'transport_timeout', now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000072', :'U9', :'Q1', :'S_SMALL', 2, 'web', 'search',
   '{"q":"fixture small retry probe"}'::jsonb,
   '{"hits":4}'::jsonb, true, NULL, now() - interval '3 hours'),
  ('7a000000-0000-4000-8000-000000000073', :'U9', :'Q1', :'S_SMALL', 3, 'graph', 'status',
   '{"op":"status"}'::jsonb,
   '{"claims":144,"evidence":210}'::jsonb, true, NULL, now() - interval '3 hours'),
  -- S_SYN: the report-writing session's one call
  ('7a000000-0000-4000-8000-000000000081', :'U9', :'Q3', :'S_SYN', 1, 'graph', 'status',
   '{"op":"status"}'::jsonb,
   '{"claims":5,"evidence":0}'::jsonb, true, NULL, now() - interval '75 minutes'),
  -- S_WEDGE: the stall fixture — events 45 minutes stale while the session
  -- row still claims to be live; the LAST call is a spawn (FM-20 flavor:
  -- 'no tool result' does NOT imply 'no process')
  ('7a000000-0000-4000-8000-000000000091', :'U9', :'Q4', :'S_WEDGE', 1, 'graph', 'status',
   '{"op":"status"}'::jsonb,
   '{"claims":150,"evidence":240}'::jsonb, true, NULL, now() - interval '45 minutes'),
  ('7a000000-0000-4000-8000-000000000092', :'U9', :'Q4', :'S_WEDGE', 2, 'spawn', 'dispatch',
   '{"cmd":"fixture-child-01","detach":true}'::jsonb,
   '{"run":"fix-child-01","status":"launched"}'::jsonb, true, NULL, now() - interval '44 minutes'),
  -- S_TRICK: the trickle — one tiny fresh event (well inside the window,
  -- payload far below 100 B): SLOWSTALL, not WEDGE
  ('7a000000-0000-4000-8000-000000000101', :'U9', :'Q5', :'S_TRICK', 1, 'graph', 'status',
   '{"op":"status"}'::jsonb,
   '{"ack":"tick"}'::jsonb, true, NULL, now() - interval '2 minutes'),
  -- S_OK: the clean live counter-case — fresh, healthy, well over 100 B
  ('7a000000-0000-4000-8000-000000000111', :'U9', :'Q6', :'S_OK', 1, 'graph', 'status',
   '{"op":"status"}'::jsonb,
   '{"claims":210,"evidence":354,"frontier_open":88,"frontier_mass":1319,"bare_claims":0,"unreferenced":0,"dual_arm_claims":0,"decompose_remaining":0}'::jsonb,
   true, NULL, now()),
  ('7a000000-0000-4000-8000-000000000112', :'U9', :'Q6', :'S_OK', 2, 'web', 'fetch_save',
   '{"url":"https://fixture.example/clean-live-corpus-note"}'::jsonb,
   '{"ok":true,"source":"kb:src","budget":{"web_calls_used":12}}'::jsonb, true, NULL, now()),
  -- S_NEAR (judge F1/F3): TWO unknown-tool refusals (2 < 3 for
  -- tw_shape_storm — the count-axis quiet proof)
  ('7a000000-0000-4000-8000-000000000301', :'U9', :'Q8', :'S_NEAR', 1, 'made_up_tool', 'explode',
   '{"why":"count-axis near miss"}'::jsonb, '{"error":"no such tool: made_up_tool"}'::jsonb,
   false, 'unknown_tool', now() - interval '29 minutes'),
  ('7a000000-0000-4000-8000-000000000302', :'U9', :'Q8', :'S_NEAR', 2, 'made_up_tool', 'explode',
   '{"why":"count-axis near miss"}'::jsonb, '{"error":"no such tool: made_up_tool"}'::jsonb,
   false, 'unknown_tool', now() - interval '28 minutes'),
  -- S_NEAR: TWO non-sliced-read refusals (2 < 3 for tw_context_blowout)
  ('7a000000-0000-4000-8000-000000000303', :'U9', :'Q8', :'S_NEAR', 3, 'source_read', NULL,
   '{"source":"urn:fixture:near-miss-1"}'::jsonb,
   '{"error":"NON-SLICED-READ: ..."}'::jsonb,
   false, 'non_sliced_read', now() - interval '27 minutes'),
  ('7a000000-0000-4000-8000-000000000304', :'U9', :'Q8', :'S_NEAR', 4, 'source_read', NULL,
   '{"source":"urn:fixture:near-miss-2"}'::jsonb,
   '{"error":"NON-SLICED-READ: ..."}'::jsonb,
   false, 'non_sliced_read', now() - interval '26 minutes'),
  -- S_BLOW: THE FM-22 CONTEXT-BLOWOUT STORM (judge F1) — the teaching
  -- refusal ignored three times in one session
  ('7a000000-0000-4000-8000-000000000311', :'U9', :'Q8', :'S_BLOW', 1, 'source_read', NULL,
   '{"source":"urn:fixture:blowout-1"}'::jsonb,
   '{"error":"NON-SLICED-READ: ..."}'::jsonb,
   false, 'non_sliced_read', now() - interval '24 minutes'),
  ('7a000000-0000-4000-8000-000000000312', :'U9', :'Q8', :'S_BLOW', 2, 'source_read', NULL,
   '{"source":"urn:fixture:blowout-2"}'::jsonb,
   '{"error":"NON-SLICED-READ: ..."}'::jsonb,
   false, 'non_sliced_read', now() - interval '23 minutes'),
  ('7a000000-0000-4000-8000-000000000313', :'U9', :'Q8', :'S_BLOW', 3, 'source_read', NULL,
   '{"source":"urn:fixture:blowout-3"}'::jsonb,
   '{"error":"NON-SLICED-READ: ..."}'::jsonb,
   false, 'non_sliced_read', now() - interval '22 minutes'),
  -- S_BLOW: the legal alternative afterwards (the teaching eventually
  -- lands — the storm fired on the three before it)
  ('7a000000-0000-4000-8000-000000000314', :'U9', :'Q8', :'S_BLOW', 4, 'source_read', NULL,
   '{"source":"urn:fixture:blowout-1","offset":1,"limit":60}'::jsonb,
   '{"lines":[42]}'::jsonb, true, NULL, now() - interval '21 minutes'),
  -- S_NEAR + S_BLOW: one FRESH healthy event each inside the SR-18 window
  -- (keeps the near-miss sessions out of tw_wedge — their old events are
  -- deliberate, not stalls) and >= 100 B of window bytes (out of tw_slowstall)
  ('7a000000-0000-4000-8000-000000000305', :'U9', :'Q8', :'S_NEAR', 5, 'graph', 'status',
   '{"k":"status"}'::jsonb, to_jsonb(repeat('s', 400)), true, NULL, now() - interval '2 minutes'),
  ('7a000000-0000-4000-8000-000000000315', :'U9', :'Q8', :'S_BLOW', 5, 'graph', 'status',
   '{"k":"status"}'::jsonb, to_jsonb(repeat('s', 400)), true, NULL, now() - interval '1 minute')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- usage_events fixtures (D10 spend ledger; the FM-01/FM-24/FM-25 signals)
-- ---------------------------------------------------------------------------
INSERT INTO usage_events (id, user_id, quest_id, phase_id, session_id, kind, model,
                          input_tokens, output_tokens, cache_read_tokens, cost_usd, created_at) VALUES
  -- S_CEIL: one ordinary billable row
  ('7b000000-0000-4000-8000-000000000001', :'U9', :'Q1', :'P_DES1', :'S_CEIL', 'llm', 'glm-5.3',
   90000, 1500, 85000, 0.021000, now() - interval '3 hours'),
  -- S_CHURN: recovery loop tokens
  ('7b000000-0000-4000-8000-000000000011', :'U9', :'Q1', :'P_DES1', :'S_CHURN', 'llm', 'glm-5.3',
   40000, 800, 35000, 0.008000, now() - interval '3 hours'),
  -- S_REPLAY
  ('7b000000-0000-4000-8000-000000000021', :'U9', :'Q1', :'P_DES1', :'S_REPLAY', 'llm', 'glm-5.3',
   30000, 500, 26000, 0.006000, now() - interval '3 hours'),
  -- S_EMPTY: THE EMPTY-COMPLETION STORM — 3 rows of a real request billed on
  -- input with zero output (FM-01 signature: rc=0, terminal empty assistant
  -- event; the local-model empty-completion deaths of v3 phase-105)
  ('7b000000-0000-4000-8000-000000000031', :'U9', :'Q1', :'P_DES1', :'S_EMPTY', 'llm', 'tf-qwen3.8-flash-next-4bit',
   120000, 0, 110000, 0.004000, now() - interval '2 hours 50 minutes'),
  ('7b000000-0000-4000-8000-000000000032', :'U9', :'Q1', :'P_DES1', :'S_EMPTY', 'llm', 'tf-qwen3.8-flash-next-4bit',
   120000, 0, 110000, 0.004000, now() - interval '2 hours 45 minutes'),
  ('7b000000-0000-4000-8000-000000000033', :'U9', :'Q1', :'P_DES1', :'S_EMPTY', 'llm', 'tf-qwen3.8-flash-next-4bit',
   120000, 0, 110000, 0.004000, now() - interval '2 hours 40 minutes'),
  -- S_CACHE: the prefix-cache wall — 4 consecutive high-context turns with
  -- cache_read = 0 (FM-24: every turn pays the full re-prefill)
  ('7b000000-0000-4000-8000-000000000041', :'U9', :'Q1', :'P_DES1', :'S_CACHE', 'llm', 'tf-qwen3.8-flash-next-4bit',
   230000, 640, 0, 0.086000, now() - interval '2 hours 35 minutes'),
  ('7b000000-0000-4000-8000-000000000042', :'U9', :'Q1', :'P_DES1', :'S_CACHE', 'llm', 'tf-qwen3.8-flash-next-4bit',
   231000, 610, 0, 0.086500, now() - interval '2 hours 30 minutes'),
  ('7b000000-0000-4000-8000-000000000043', :'U9', :'Q1', :'P_DES1', :'S_CACHE', 'llm', 'tf-qwen3.8-flash-next-4bit',
   232000, 590, 0, 0.087000, now() - interval '2 hours 25 minutes'),
  ('7b000000-0000-4000-8000-000000000044', :'U9', :'Q1', :'P_DES1', :'S_CACHE', 'llm', 'tf-qwen3.8-flash-next-4bit',
   233000, 570, 0, 0.087500, now() - interval '2 hours 20 minutes'),
  -- S_SHAPE
  ('7b000000-0000-4000-8000-000000000051', :'U9', :'Q1', :'P_DES1', :'S_SHAPE', 'llm', 'glm-5.3',
   35000, 600, 30000, 0.007000, now() - interval '2 hours 15 minutes'),
  -- S_SMALL: clean low-context warm turn + a HIGH-context CACHED turn
  -- (cache_read > 0 — the false-positive proof for tw_cache_wall)
  ('7b000000-0000-4000-8000-000000000061', :'U9', :'Q1', :'P_DES1', :'S_SMALL', 'llm', 'glm-5.3',
   50000, 900, 48000, 0.010000, now() - interval '2 hours 10 minutes'),
  ('7b000000-0000-4000-8000-000000000062', :'U9', :'Q1', :'P_DES1', :'S_SMALL', 'llm', 'glm-5.3',
   230000, 700, 210000, 0.020000, now() - interval '2 hours 5 minutes'),
  -- S_SYN: the report-writing turn
  ('7b000000-0000-4000-8000-000000000071', :'U9', :'Q3', :'P_SYN3', :'S_SYN', 'llm', 'glm-5.3',
   70000, 3000, 60000, 0.030000, now() - interval '60 minutes'),
  -- S_WEDGE: last ledger row 45 minutes stale (the frozen ledger IS the signal)
  ('7b000000-0000-4000-8000-000000000081', :'U9', :'Q4', :'P_ROT4', :'S_WEDGE', 'llm', 'glm-5.3',
   96000, 1200, 88000, 0.024000, now() - interval '45 minutes'),
  -- S_TRICK: tiny fresh turn
  ('7b000000-0000-4000-8000-000000000091', :'U9', :'Q5', :'P_DES5', :'S_TRICK', 'llm', 'tf-qwen3.8-flash-next-4bit',
   8000, 12, 7000, 0.000300, now() - interval '2 minutes'),
  -- S_OK: three clean turns — warm low-context, ONE isolated empty completion
  -- (normal FM-01 retry life: 1 < 3, stays quiet), then a cached high-context
  -- turn with cache_read > 0 (quiet on tw_cache_wall)
  ('7b000000-0000-4000-8000-000000000101', :'U9', :'Q6', :'P_DES6', :'S_OK', 'llm', 'glm-5.3',
   60000, 400, 55000, 0.009000, now() - interval '4 minutes'),
  ('7b000000-0000-4000-8000-000000000102', :'U9', :'Q6', :'P_DES6', :'S_OK', 'llm', 'glm-5.3',
   230000, 0, 224000, 0.041000, now() - interval '3 minutes'),
  ('7b000000-0000-4000-8000-000000000103', :'U9', :'Q6', :'P_DES6', :'S_OK', 'llm', 'glm-5.3',
   230000, 900, 215000, 0.043000, now() - interval '1 minute'),
  -- S_NEAR (judge F3 near-miss): TWO isolated empty completions (2 < 3 —
  -- the count-axis quiet proof for tw_empty_storm; P_DES8 carries exactly 2)
  ('7b000000-0000-4000-8000-000000000201', :'U9', :'Q8', :'P_DES8', :'S_NEAR', 'llm', 'glm-5.3',
   50000, 0, 44000, 0.010000, now() - interval '28 minutes'),
  ('7b000000-0000-4000-8000-000000000202', :'U9', :'Q8', :'P_DES8', :'S_NEAR', 'llm', 'glm-5.3',
   52000, 0, 46000, 0.010500, now() - interval '27 minutes'),
  -- S_NEAR cache-axis near-misses: TWO uncacheable high-context turns
  -- (2 < 3 for tw_cache_wall) + ONE just-under-wall turn (204999 < 205000
  -- pins the input threshold downward)
  ('7b000000-0000-4000-8000-000000000203', :'U9', :'Q8', :'P_DES8', :'S_NEAR', 'llm', 'glm-5.3',
   230000, 500, 0, 0.046000, now() - interval '26 minutes'),
  ('7b000000-0000-4000-8000-000000000204', :'U9', :'Q8', :'P_DES8', :'S_NEAR', 'llm', 'glm-5.3',
   235000, 500, 0, 0.047000, now() - interval '25 minutes'),
  ('7b000000-0000-4000-8000-000000000205', :'U9', :'Q8', :'P_DES8', :'S_NEAR', 'llm', 'glm-5.3',
   204999, 400, 0, 0.041000, now() - interval '24 minutes'),
  -- S_BLOW: an ordinary billable row (the storm is in the tool_calls below)
  ('7b000000-0000-4000-8000-000000000206', :'U9', :'Q8', :'P_DES9', :'S_BLOW', 'llm', 'glm-5.3',
   60000, 700, 55000, 0.012000, now() - interval '20 minutes')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- claims fixtures — the hub type-divergence pairs (v_canonical_claims) and
-- the fingerprint quests' graph content. canonical_text is the GENERATED I01
-- normalization; the fixture texts are authored already-normalized.
-- ---------------------------------------------------------------------------
INSERT INTO claims (id, user_id, quest_id, quest_seq, text, terminal_type, terminal_basis, urn) VALUES
  -- text X: same canonical text, TWO DIFFERENT typed terminals => DIVERGENT
  ('7c000000-0000-4000-8000-000000000001', :'U9', :'Q2', 1,
   'Fixture divergence text: the same canonical claim typed two ways by two quests.',
   'primary-empirical', 'fixture probe evidence set A', 'kb:claim:fixdvX21aa'),
  ('7c000000-0000-4000-8000-000000000004', :'U9', :'Q3', 1,
   'Fixture divergence text: the same canonical claim typed two ways by two quests.',
   'residual-uncertainty', 'fixture: the 2006 primary is effectively unpublished-online; the hole is recorded with its search trail', 'kb:claim:fixdvX31dd'),
  -- text Y: same text, SAME terminal type in both quests => clean coexistence
  ('7c000000-0000-4000-8000-000000000002', :'U9', :'Q2', 2,
   'Fixture clean coexistence text: two quests, same terminal type, no divergence.',
   'primary-empirical', 'fixture probe evidence set A', 'kb:claim:fixdvY21bb'),
  ('7c000000-0000-4000-8000-000000000005', :'U9', :'Q3', 2,
   'Fixture clean coexistence text: two quests, same terminal type, no divergence.',
   'primary-empirical', 'fixture probe evidence set B', 'kb:claim:fixdvY31ee'),
  -- text W: typed in Q2, UNTERMINATED in Q3 — an open claim coexisting with
  -- a typed one is NOT divergence (v_canonical_claims counts non-null types)
  ('7c000000-0000-4000-8000-000000000003', :'U9', :'Q2', 3,
   'Fixture unterminated coexistence text: typed in one quest, open in another.',
   'primary-empirical', 'fixture probe evidence set A', 'kb:claim:fixdvW21cc'),
  ('7c000000-0000-4000-8000-000000000006', :'U9', :'Q3', 3,
   'Fixture unterminated coexistence text: typed in one quest, open in another.',
   NULL, NULL, 'kb:claim:fixdvW31ff'),
  -- Q7 pre-archive graph content (the state the archive pin freezes)
  ('7c000000-0000-4000-8000-000000000008', :'U9', :'Q7', 1,
   'Fixture archive quest claim one: the pinned pre-archive state.',
   'primary-empirical', 'fixture archive evidence', 'kb:claim:fixdvN71hh')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Report pin fixture (I02 DR-17): RV1 pins the PRE-mutation fingerprint; the
-- post-synthesis mutation below then invalidates the pin => tw_fingerprint_
-- drift FIRES on RV1. RV2 pins the post-mutation live fingerprint => QUIET.
-- ---------------------------------------------------------------------------
INSERT INTO report_versions (id, user_id, quest_id, version_seq,
                              synthesis_phase_id, created_session_id, model,
                              body_blob_key, body_sha256, quest_fingerprint, standing)
SELECT :'RV1', :'U9', :'Q3', 1, :'P_SYN3', :'S_SYN', 'glm-5.3',
       'reports/77000000-0000-4000-8000-000000000003/v1.md',
       encode(sha256(convert_to('i07-fixture-report-v1', 'UTF8')), 'hex'),
       fp.graph_fingerprint, false
FROM v_quest_graph_fingerprint fp
WHERE fp.quest_id = :'Q3'
ON CONFLICT (id) DO NOTHING;

-- the POST-SYNTHESIS MUTATION: a claim added after the report pin — the
-- live fingerprint moves, RV1's pin no longer matches (the M3 drift story)
INSERT INTO claims (id, user_id, quest_id, quest_seq, text, terminal_type, terminal_basis, urn) VALUES
  ('7c000000-0000-4000-8000-000000000007', :'U9', :'Q3', 4,
   'Fixture post-synthesis mutation claim: added after the report pin.',
   NULL, NULL, 'kb:claim:fixdvM31gg')
ON CONFLICT (id) DO NOTHING;

-- RV2 pins the CURRENT (post-mutation) live fingerprint: the clean pin
INSERT INTO report_versions (id, user_id, quest_id, version_seq,
                              synthesis_phase_id, created_session_id, model,
                              body_blob_key, body_sha256, quest_fingerprint, standing)
SELECT :'RV2', :'U9', :'Q3', 2, :'P_SYN3', :'S_SYN', 'glm-5.3',
       'reports/77000000-0000-4000-8000-000000000003/v2.md',
       encode(sha256(convert_to('i07-fixture-report-v2', 'UTF8')), 'hex'),
       fp.graph_fingerprint, false
FROM v_quest_graph_fingerprint fp
WHERE fp.quest_id = :'Q3'
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Archive pin fixture (I02 DR-17, the post-archive-rework story): the Q7
-- archive event freezes the pre-rework fingerprint; the rework claim below
-- then drifts the live graph away from the pin => the archive leg of
-- tw_fingerprint_drift FIRES. The report leg stays quiet for Q7 (no RVs).
-- ---------------------------------------------------------------------------
INSERT INTO quest_lifecycle_events (id, user_id, quest_id, from_state, to_state,
                                    actor, verification_phase_id,
                                    claims_at_archive, evidence_at_archive,
                                    frontier_open_at_archive, graph_fingerprint,
                                    occurred_at, note)
SELECT :'ARC7', :'U9', :'Q7', 'complete', 'archived', 'operator', :'P_VER7',
       1, 0, 0, fp.graph_fingerprint,
       now() - interval '90 minutes',
       'fixture archive; post-archive rework follows (drifts the pin by design)'
FROM v_quest_graph_fingerprint fp
WHERE fp.quest_id = :'Q7'
ON CONFLICT (id) DO NOTHING;

-- the POST-ARCHIVE REWORK: a claim added after the freeze (legal per DR-17;
-- detected, not prevented) — the archive pin now differs from the live graph
INSERT INTO claims (id, user_id, quest_id, quest_seq, text, terminal_type, terminal_basis, urn) VALUES
  ('7c000000-0000-4000-8000-000000000009', :'U9', :'Q7', 2,
   'Fixture post-archive rework question: added after the freeze.',
   NULL, NULL, 'kb:claim:fixdvN72ii')
ON CONFLICT (id) DO NOTHING;

-- ============================================================================
-- PART B — THE CATALOG: one named tw_<id> view per signal.
-- Every header carries: detection semantics / threshold provenance /
-- signal action (SIGNAL ONLY — ENTRY 8 assurance_alert SSE slot; I06 owns
-- every transition; FM-18: never auto-kill).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- tw_wedge — the frozen-ledger wedge (FM-04 tool wedge; FM-20 spawn wedge).
-- Detection: a session row that still claims to be live (ended_at IS NULL)
-- whose durable event ledger (tool_calls + usage_events, the L8 audit) has
-- been silent for longer than the operator's stall window.
-- Threshold: SR-18 engine.slow_stall_window_s = 1200 (I06 stop-rules.tsv;
-- the operator's authoritative stall measurement window, llm-trading-v3
-- §SLOWSTALL rule added). The per-call 120 s tool watchdog is I04 FM-04's
-- harness half; this predicate catches the case where even that failed —
-- the deadline row never landed (the harness lost track).
-- Action: SIGNAL (assurance_alert). 'No tool result != no process' (FM-20):
-- the alert carries the last tool (last_tool column — 'spawn' means: check
-- the run registry by run id, NEVER infer child death from the missing
-- result). If the operator stays absent past SR-19 engine.unattended_pause_s
-- (default 3600), I06's slow_stall_unattended event pauses the quest — this
-- predicate never transitions anything and never auto-kills (FM-18).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW tw_wedge AS
WITH lastev AS (
  SELECT s.id AS session_id,
         greatest(
           s.started_at,
           coalesce((SELECT max(tc.created_at) FROM tool_calls tc
                      WHERE tc.session_id = s.id), s.started_at),
           coalesce((SELECT max(ue.created_at) FROM usage_events ue
                      WHERE ue.session_id = s.id), s.started_at)
         ) AS last_event_at
  FROM sessions s
)
SELECT s.id AS session_id, s.user_id, s.quest_id, s.phase_id, s.model,
       s.started_at, l.last_event_at,
       (extract(epoch FROM (now() - l.last_event_at)))::bigint AS last_event_age_s,
       t.tool AS last_tool, t.ok AS last_tool_ok
FROM sessions s
JOIN lastev l ON l.session_id = s.id
LEFT JOIN LATERAL (
  SELECT tc.tool, tc.ok FROM tool_calls tc
  WHERE tc.session_id = s.id
  ORDER BY tc.created_at DESC, tc.seq DESC LIMIT 1
) t ON true
WHERE s.ended_at IS NULL
  AND l.last_event_at < now() - interval '1200 seconds';  -- SR-18

-- ---------------------------------------------------------------------------
-- tw_slowstall — SLOWSTALL, the durable-ledger projection (FM-18).
-- Detection: a live session whose ledger IS flowing (>= 1 event inside
-- the window — that is tw_wedge's signature, not this one) but whose
-- window payload is under the growth threshold: events trickling, bytes
-- below the operator's stall line.
-- Threshold: SR-17 engine.slow_stall_bytes = 100 over SR-18
-- engine.slow_stall_window_s = 1200 (I06 stop-rules.tsv; FM-18; the local-
-- model ruling: slow phases are EXPECTED — this is alert-only).
-- Payload = octet_length(args::text) + octet_length(result::text): the
-- verbatim audit bytes ARE transcript bytes (L8), a durable LOWER BOUND of
-- the live transcript (DR-07; the byte-accurate live form rides the ENTRY 8
-- watcher with these same SR-17/18 keys).
-- Action: SIGNAL only, alert text carries the FM-18 rule: the driver is NOT
-- to be killed on this alone; expected pace under slow local models.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW tw_slowstall AS
SELECT s.id AS session_id, s.user_id, s.quest_id, s.phase_id, s.model,
       s.started_at,
       w.window_events, w.window_bytes
FROM sessions s
JOIN LATERAL (
  SELECT count(*) AS window_events,
         coalesce(sum(octet_length(tc.args::text) + octet_length(tc.result::text)), 0) AS window_bytes
  FROM tool_calls tc
  WHERE tc.session_id = s.id
    AND tc.created_at > now() - interval '1200 seconds'  -- SR-18
) w ON true
WHERE s.ended_at IS NULL
  AND w.window_events >= 1      -- flowing ledger: distinguishes SLOWSTALL from WEDGE
  AND w.window_bytes < 100;     -- SR-17

-- ---------------------------------------------------------------------------
-- tw_size_ceiling — SIZE-CEILING, the ceiling-band transcript (FM-02).
-- Detection: a session whose cumulative verbatim audit payload has entered
-- the ceiling BAND. The PoC measured deterministic transcript-size deaths at
-- 496,294 B and 496,578 B (284 B apart, llm-trading-v3 §Post-resume ground
-- truth); the early-warning line gives the operator runway ahead of the hard
-- ceiling (SR-15 refuse new corpus ingestion / bank at the turn boundary;
-- SR-16 end the session, then the I04 DR-06 runtime operator menu — never
-- truncate a live transcript mid-flight, L8).
-- Threshold: SR-15 engine.transcript_ceiling_warn_bytes = 450000 (fires);
-- SR-16 engine.transcript_ceiling_hard_bytes = 496000 (band='hard').
-- Honesty: audit bytes are a LOWER BOUND of the live transcript — firing is
-- reliable, quiet is not proof (DR-07); the ENTRY 8 watcher reads the live
-- blob size with these same keys.
-- Action: SIGNAL (assurance_alert, band in the payload); no transitions —
-- SR-15/16's runtime handling is I06/I04 law, this predicate only detects.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW tw_size_ceiling AS
SELECT s.id AS session_id, s.user_id, s.quest_id, s.phase_id, s.model,
       b.audit_bytes,
       CASE WHEN b.audit_bytes >= 496000 THEN 'hard' ELSE 'warn' END AS band
FROM sessions s
JOIN LATERAL (
  SELECT coalesce(sum(octet_length(tc.args::text) + octet_length(tc.result::text)), 0) AS audit_bytes
  FROM tool_calls tc
  WHERE tc.session_id = s.id
) b ON true
WHERE b.audit_bytes >= 450000;  -- SR-15; band hard at SR-16's 496000

-- ---------------------------------------------------------------------------
-- tw_churn — the refusal/error churn loop (babysitter v3 CHURN counter;
-- quest-3 SKILL law 1; quest-2 failure taxonomy).
-- Detection: a session with a run of >= 10 consecutive failed tool calls
-- (the ledger keeps flowing — results are refusals, not silence; that is
-- churn, not wedge).
-- Threshold: 10 consecutive — the quest-3 dedup-search-cap law (">~10
-- consecutive searches with no mutation -> STOP", llm-trading-v3 §SKILL
-- graft law 1) calibrated against the quest-2 taxonomy's measured burst
-- shape (max 8-identical refusal burst width, 12 max class-a refusals per
-- session — arc-run-20261121T §1). DECISIONS DR-09.
-- Action: SIGNAL; a stuck recovery loop is operator-visible material, but
-- in-band teaching refusals are the DESIGNED mechanism (I05) — the loop
-- keeps running; no transition, no kill.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW tw_churn AS
WITH runs AS (
  SELECT tc.session_id, tc.seq, tc.ok,
         row_number() OVER (PARTITION BY tc.session_id ORDER BY tc.seq)
       - row_number() OVER (PARTITION BY tc.session_id, tc.ok ORDER BY tc.seq) AS grp
  FROM tool_calls tc
)
SELECT r.session_id, count(*) AS consecutive_failures,
       min(r.seq) AS first_seq, max(r.seq) AS last_seq
FROM runs r
WHERE r.ok = false
GROUP BY r.session_id, r.grp
HAVING count(*) >= 10;

-- ---------------------------------------------------------------------------
-- tw_rotation — phase rotation without completion (babysitter v3's
-- phase-rotation liveness check, inverted).
-- Detection: a phase attempt row whose attempt_no is beyond the phase
-- retry cap while the phase is still unfinished — the quest is cycling
-- attempts (wall kills, empty-completion deaths) without landing.
-- Threshold: SR-08 phase retry cap default 3 (I06 stop-rules.tsv; PoC
-- RETRY_CAP=3, quest-2 §Wall kills, v3 phase-105's six deaths) — fires at
-- attempt_no > 3.
-- Action: SIGNAL; the pause-and-present move at cap exhaustion is I06's
-- transition row (retry_cap_exhausted -> paused) — this predicate never
-- transitions. A raised cap (v3's RETRY_CAP=8 relaunch) is an operator
-- decision the signal makes visible.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW tw_rotation AS
SELECT p.id AS phase_id, p.user_id, p.quest_id, p.kind, p.round_no,
       p.attempt_no, p.state
FROM phases p
WHERE p.attempt_no > 3                                -- SR-08 (default 3)
  AND p.state IN ('pending', 'running', 'failed');

-- ---------------------------------------------------------------------------
-- tw_empty_storm — the empty-completion storm (FM-01).
-- Detection: >= 3 usage rows in one phase attempt whose request was real
-- (input billed) but whose completion came back empty (output_tokens = 0)
-- — the PoC's terminal-empty-assistant-event signature (rc=0, no error,
-- 15-17 ms after tool results; llm-trading-v3 §degenerate EMPTY
-- completions; the v3 phase-105 five-death cluster).
-- Threshold: 3 = SR-08 phase retry cap (I06 stop-rules.tsv): three
-- consecutive empties exhaust a phase attempt by the measured default.
-- Zero-token all-zero rows are the FM-25 zero-usage recording, NOT this
-- signature — input_tokens > 0 discriminates.
-- Action: SIGNAL (the model may just be flaky — FM-01 is retryable with a
-- fresh seed); the attempt-cap pause is I06's law.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW tw_empty_storm AS
SELECT ue.phase_id, ue.quest_id, ue.user_id, count(*) AS empty_completions
FROM usage_events ue
WHERE ue.kind = 'llm'
  AND ue.input_tokens > 0        -- a real request (not the FM-25 zero row)
  AND ue.output_tokens = 0       -- the FM-01 empty completion
GROUP BY ue.phase_id, ue.quest_id, ue.user_id
HAVING count(*) >= 3;             -- SR-08

-- ---------------------------------------------------------------------------
-- tw_repetition — the replay loop (FM-03).
-- Detection: >= 3 consecutive byte-identical tool calls (same tool, op and
-- args) in one session — the durable signature of a retry loop that never
-- mutates state ("a failed call that does not mutate state produces an
-- identical retry body", gateway-20261118T §identical retry bodies).
-- Threshold: 3 — past the transport-retry caps (FM-05/FM-06/FM-08 default
-- 3): a legal bounded retry (identical body, fresh seed) stays under it;
-- the S_SMALL fixture pair proves the quiet side.
-- Action: SIGNAL ('alert on repetition' — FM-03; prevention is I04's
-- seed-variation law, not this predicate's).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW tw_repetition AS
WITH marked AS (
  SELECT tc.session_id, tc.seq, tc.tool, tc.op,
         (tc.tool || '|' || coalesce(tc.op, '') || '|' || tc.args::text) AS body,
         ((tc.tool || '|' || coalesce(tc.op, '') || '|' || tc.args::text) IS DISTINCT FROM
          lag(tc.tool || '|' || coalesce(tc.op, '') || '|' || tc.args::text)
            OVER (PARTITION BY tc.session_id ORDER BY tc.seq)) AS run_start
  FROM tool_calls tc
), runs AS (
  SELECT session_id, seq, tool, op, body,
         sum(run_start::int) OVER (PARTITION BY session_id ORDER BY seq) AS grp
  FROM marked
)
SELECT session_id, tool, op, count(*) AS consecutive_identical,
       min(seq) AS first_seq, max(seq) AS last_seq
FROM runs
GROUP BY session_id, grp, tool, op
HAVING count(*) >= 3;

-- ---------------------------------------------------------------------------
-- tw_missing_spend — the missing spend row (FM-25).
-- Detection: an ENDED session that made tool calls but recorded not one
-- llm usage_events row — spend would silently under-record (D10 cost
-- honesty; "a missing row at rollup time is an ENTRY 7 tripwire" —
-- FM-25). Scoped to ended sessions: a live session mid-first-turn has no
-- rollup yet and must not false-positive.
-- Action: SIGNAL (a ledger defect, not a model defect — the operator
-- checks the telemetry sink wiring; the gem contract 'EXACTLY ONE terminal
-- hook per completion' is I04 law).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW tw_missing_spend AS
SELECT s.id AS session_id, s.user_id, s.quest_id, s.phase_id,
       count(tc.id) AS tool_calls
FROM sessions s
JOIN tool_calls tc ON tc.session_id = s.id
WHERE s.ended_at IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM usage_events ue
                  WHERE ue.session_id = s.id AND ue.kind = 'llm')
GROUP BY s.id, s.user_id, s.quest_id, s.phase_id;

-- ---------------------------------------------------------------------------
-- tw_cache_wall — the prefix-cache wall (FM-24).
-- Detection: >= 3 high-context turns in one session with cache_read = 0 —
-- above the effective wall every turn pays the full re-prefill (measured:
-- a 262k window with an 8GiB prefix cache has an effective wall ~205k,
-- arc-run-20261122T-quest2-arc-summary §Cache-wall economics).
-- Threshold: input_tokens >= 205000 (FM-24's measured effective wall,
-- per-provider config cache_wall_tokens) and cache_read_tokens = 0,
-- count >= 3 (the FM family's alert default — FM-12/FM-14 use 3).
-- Action: SIGNAL; the routing fix (mega-context phases to cache-capable
-- models) is I06 §7's routing map — the operator re-routes, never the
-- predicate.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW tw_cache_wall AS
SELECT ue.session_id, ue.user_id, ue.quest_id,
       count(*) AS uncacheable_high_context_turns,
       max(ue.input_tokens) AS max_input_tokens
FROM usage_events ue
WHERE ue.kind = 'llm'
  AND ue.input_tokens >= 205000    -- FM-24 measured effective wall
  AND ue.cache_read_tokens = 0
GROUP BY ue.session_id, ue.user_id, ue.quest_id
HAVING count(*) >= 3;

-- ---------------------------------------------------------------------------
-- tw_shape_storm — the tool-shape honesty storm (FM-11 + FM-12; FM-14's
-- threshold default).
-- Detection: >= 3 calls in one session refused for stream/shape honesty
-- classes (unknown_tool: the model names a tool absent from its surface;
-- tool_arguments_failure: unparseable arguments at stream finalize). Both
-- are DESIGNED in-band self-correction mechanisms (the refusal teaches,
-- the model re-calls) — a storm means the self-correction is not landing.
-- Threshold: 3 — unknown_tool_alert_at default 3 (FM-12) and
-- dropped_chunk_alert_threshold default 3 (FM-14): the family's alert
-- default. (FM-14's dropped-chunk count itself is a runtime/gem counter,
-- not a tool_calls error_class — it rides the ENTRY 8 watcher; noted here
-- for provenance, not as SQL.)
-- Action: SIGNAL — a stuck model, not a bad call (FM-12's escalation
-- rule); the loop keeps running.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW tw_shape_storm AS
SELECT tc.session_id, tc.user_id, tc.quest_id, count(*) AS shape_errors
FROM tool_calls tc
WHERE tc.error_class IN ('unknown_tool', 'tool_arguments_failure')
GROUP BY tc.session_id, tc.user_id, tc.quest_id
HAVING count(*) >= 3;

-- ---------------------------------------------------------------------------
-- tw_context_blowout — the full-file read storm (FM-22; judge F1).
-- Detection: >= 3 non_sliced_read refusals in one session — the I05 frozen
-- teaching refusal (the non-sliced-read text names the slice form and the
-- grep-first pattern) ignored three times in a row: the 78% lesson's
-- failure shape (corpus ingestion via full-file reads was 78% of a
-- 79,677-token final context — 2026-11-17-arc-decompose-review.md §Q5).
-- Threshold: 3 — the FM family's alert default (FM-12/FM-14 use 3); the
-- S_NEAR fixture pair (2 refusals) proves the quiet side. The I05 tool
-- boundary (read_slice hard-capped per I05 DR-04/A) and the I04 cache-wall
-- tripwire (FM-24) are the backstops; this predicate detects the TEACHING
-- NOT LANDING, not the ingestion itself.
-- Action: SIGNAL (assurance_alert) — the operator sees a model ignoring
-- the read discipline; the fix is behavioral (phase prompt / overlay),
-- never a kill.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW tw_context_blowout AS
SELECT tc.session_id, tc.user_id, tc.quest_id,
       count(*) AS non_sliced_read_refusals
FROM tool_calls tc
WHERE tc.ok = false
  AND tc.error_class = 'non_sliced_read'
GROUP BY tc.session_id, tc.user_id, tc.quest_id
HAVING count(*) >= 3;   -- the FM family's alert default (FM-12/FM-14 = 3)

-- ---------------------------------------------------------------------------
-- tw_hub_divergence — the cross-quest type-divergence tripwire (D3/I02;
-- I02 queries-i02.sql M1 leg 2 is this predicate's seed).
-- Detection: hub entries (v_canonical_claims) whose (user, canonical
-- text) carries more than one distinct NON-NULL terminal_type — same
-- claim, conflicting typed verdicts, in different quests. Same-text-same-
-- type coexists cleanly; a typed entry coexisting with an UNTERMINATED one
-- does NOT fire (an open claim is not a conflicting verdict — both quiet
-- sides are fixture-proven below).
-- Threshold: none — divergence is exact, not calibrated (identity =
-- user_id + canonical_text + terminal_type, I02 DR-02/DR-16).
-- Action: SIGNAL (assurance_alert) — 'divergence = tripwire signal
-- (ENTRY 7), adjudicated in the source quest' (D3). The hub is derived; it
-- holds no state to fix — the conflict adjudication workflow (DESIGN §3)
-- owns the follow-up: ledger a conflicts row, hypothesize, cross-examine.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW tw_hub_divergence AS
SELECT v.user_id, v.canonical_text, v.terminal_type, v.member_claim_ids,
       v.quest_count, v.first_seen, v.latest_seen
FROM v_canonical_claims v
WHERE v.type_divergent;

-- ---------------------------------------------------------------------------
-- tw_fingerprint_drift — the staleness tripwire (I02 DR-17; queries-i02.sql
-- M3 is this predicate's seed).
-- Detection: any pinned graph fingerprint that no longer equals the live
-- quest fingerprint — two pin kinds: report versions pin the graph at
-- synthesis time (a stale version is never silently fresh, R-024) and
-- archive events pin the graph at freeze (post-archive rework is LEGAL and
-- drifts the pin by design — detected, not prevented).
-- Threshold: none — drift is exact inequality (fingerprint algorithm:
-- v_quest_graph_fingerprint, I02 schema-i02.sql).
-- Action: SIGNAL (assurance_alert, pin_kind in the payload). Stale
-- hygiene (supersede + re-synthesize) is an operator/phase decision; a
-- drifted archive pin is INFORMATION about a reworked quest, not a
-- violation.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW tw_fingerprint_drift AS
SELECT rv.quest_id, rv.user_id, 'report_pin'::text AS pin_kind,
       rv.version_seq, rv.id AS report_version_id,
       rv.quest_fingerprint AS pinned_fingerprint,
       fp.graph_fingerprint AS live_fingerprint
FROM report_versions rv
JOIN v_quest_graph_fingerprint fp ON fp.quest_id = rv.quest_id
WHERE rv.quest_fingerprint <> fp.graph_fingerprint
UNION ALL
SELECT e.quest_id, e.user_id, 'archive_pin'::text AS pin_kind,
       NULL::integer AS version_seq, NULL::uuid AS report_version_id,
       e.graph_fingerprint AS pinned_fingerprint,
       fp.graph_fingerprint AS live_fingerprint
FROM quest_lifecycle_events e
JOIN v_quest_graph_fingerprint fp ON fp.quest_id = e.quest_id
WHERE e.to_state = 'archived'
  AND e.graph_fingerprint <> fp.graph_fingerprint;

-- ============================================================================
-- PART C — SELF-VERIFICATION (I01 temp-table assert idiom, plpgsql-free).
-- Fire asserts are EXACT (got = want), scoped to the fixture tenant U9, so
-- global counts may include prior-law seed data without corrupting the
-- gate. Quiet asserts prove the false-positive side: the clean fixtures
-- appear in NO predicate. The ALTERs at the end abort the whole load on any
-- violation; the SELECTs print the evidence.
-- ============================================================================
CREATE TEMP TABLE tw_fire_asserts (
  check_name text PRIMARY KEY,
  got  integer NOT NULL,
  want  integer NOT NULL
);
CREATE TEMP TABLE tw_quiet_asserts (
  check_name text PRIMARY KEY,
  got  integer NOT NULL
);

\echo '=== fire asserts (got vs want, fixture tenant scope) ==='
INSERT INTO tw_fire_asserts (check_name, got, want) VALUES
  -- WEDGE: fires on the stall fixture, last call was the spawn
  ('wedge_fires_for_fixture_tenant',
   (SELECT count(*) FROM tw_wedge WHERE user_id = :'U9'), 1),
  ('wedge_fixture_is_the_frozen_session',
   (SELECT count(*) FROM tw_wedge WHERE session_id = :'S_WEDGE'), 1),
  ('wedge_last_tool_is_the_spawn_fm20',
   (SELECT count(*) FROM tw_wedge WHERE session_id = :'S_WEDGE' AND last_tool = 'spawn'), 1),
  -- SLOWSTALL: fires on the trickle fixture
  ('slowstall_fires_for_fixture_tenant',
   (SELECT count(*) FROM tw_slowstall WHERE user_id = :'U9'), 1),
  ('slowstall_fixture_is_the_trickle_session',
   (SELECT count(*) FROM tw_slowstall WHERE session_id = :'S_TRICK'), 1),
  ('slowstall_window_bytes_below_100',
   (SELECT count(*) FROM tw_slowstall WHERE session_id = :'S_TRICK' AND window_bytes < 100), 1),
  -- SIZE-CEILING: fires in the warn band, below the hard ceiling
  ('size_ceiling_fires_for_fixture_tenant',
   (SELECT count(*) FROM tw_size_ceiling WHERE user_id = :'U9'), 1),
  ('size_ceiling_fixture_in_warn_band',
   (SELECT count(*) FROM tw_size_ceiling WHERE session_id = :'S_CEIL' AND band = 'warn'), 1),
  ('size_ceiling_fixture_below_hard_ceiling',
   (SELECT count(*) FROM tw_size_ceiling WHERE session_id = :'S_CEIL'
      AND audit_bytes >= 450000 AND audit_bytes < 496000), 1),
  -- CHURN: fires on the 10-refusal burst
  ('churn_fires_for_fixture_tenant',
   (SELECT count(*) FROM tw_churn WHERE session_id = :'S_CHURN'), 1),
  ('churn_run_length_is_ten',
   (SELECT count(*) FROM tw_churn WHERE session_id = :'S_CHURN' AND consecutive_failures = 10), 1),
  -- ROTATION: fires on the beyond-cap attempt
  ('rotation_fires_for_fixture_tenant',
   (SELECT count(*) FROM tw_rotation WHERE user_id = :'U9'), 1),
  ('rotation_fixture_is_beyond_cap_attempt',
   (SELECT count(*) FROM tw_rotation WHERE phase_id = :'P_ROT4' AND attempt_no = 4), 1),
  -- EMPTY STORM: fires on the phase with 3 empty completions
  ('empty_storm_fires_for_fixture_tenant',
   (SELECT count(*) FROM tw_empty_storm WHERE user_id = :'U9'), 1),
  ('empty_storm_fixture_counts_three',
   (SELECT count(*) FROM tw_empty_storm WHERE phase_id = :'P_DES1' AND empty_completions = 3), 1),
  -- REPETITION: fires on the identical-body loop
  ('repetition_fires_for_fixture_tenant',
   (SELECT count(*) FROM tw_repetition WHERE session_id = :'S_REPLAY'), 1),
  -- MISSING SPEND: fires on the ended spendless session
  ('missing_spend_fires_for_fixture_tenant',
   (SELECT count(*) FROM tw_missing_spend WHERE user_id = :'U9'), 1),
  ('missing_spend_fixture_is_the_spendless_session',
   (SELECT count(*) FROM tw_missing_spend WHERE session_id = :'S_NOSPEND'), 1),
  -- CACHE WALL: fires on the cache_read=0 high-context run
  ('cache_wall_fires_for_fixture_tenant',
   (SELECT count(*) FROM tw_cache_wall WHERE session_id = :'S_CACHE'), 1),
  -- SHAPE STORM: fires on the unknown-tool storm
  ('shape_storm_fires_for_fixture_tenant',
   (SELECT count(*) FROM tw_shape_storm WHERE session_id = :'S_SHAPE'), 1),
  -- CONTEXT BLOWOUT (FM-22; judge F1): fires on the 3-refusal storm
  ('context_blowout_fires_for_fixture_tenant',
   (SELECT count(*) FROM tw_context_blowout WHERE user_id = :'U9'), 1),
  ('context_blowout_fixture_counts_three',
   (SELECT count(*) FROM tw_context_blowout WHERE session_id = :'S_BLOW'
      AND non_sliced_read_refusals = 3), 1),
  -- HUB DIVERGENCE: fires on the two-type text, both entries flagged
  ('hub_divergence_fires_both_entries_for_tenant',
   (SELECT count(*) FROM tw_hub_divergence WHERE user_id = :'U9'), 2),
  ('hub_divergence_fixture_text_carries_both_types',
   (SELECT count(*) FROM tw_hub_divergence WHERE user_id = :'U9'
      AND canonical_text = 'Fixture divergence text: the same canonical claim typed two ways by two quests.'
      AND terminal_type IN ('primary-empirical', 'residual-uncertainty')), 2),
  -- FINGERPRINT DRIFT: report pin stale + archive pin drifted
  ('fingerprint_drift_report_pin_fires',
   (SELECT count(*) FROM tw_fingerprint_drift WHERE quest_id = :'Q3' AND pin_kind = 'report_pin'), 1),
  ('fingerprint_drift_stale_version_is_rv1',
   (SELECT count(*) FROM tw_fingerprint_drift WHERE report_version_id = :'RV1'), 1),
  ('fingerprint_drift_archive_pin_fires',
   (SELECT count(*) FROM tw_fingerprint_drift WHERE quest_id = :'Q7' AND pin_kind = 'archive_pin'), 1),
  -- fixture sanity (vacuity proofs: the quiet asserts are not vacuous)
  ('fixture_clean_same_type_entry_coexists',
   (SELECT count(*) FROM v_canonical_claims WHERE user_id = :'U9'
      AND canonical_text = 'Fixture clean coexistence text: two quests, same terminal type, no divergence.'
      AND quest_count = 2 AND NOT type_divergent), 1),
  ('fixture_untyped_entry_coexists_two_rows',
   (SELECT count(*) FROM v_canonical_claims WHERE user_id = :'U9'
      AND canonical_text = 'Fixture unterminated coexistence text: typed in one quest, open in another.'), 2),
  ('fixture_fresh_pin_rv2_exists',
   (SELECT count(*) FROM report_versions WHERE id = :'RV2'), 1),
  ('fixture_clean_live_session_has_events',
   (SELECT count(*) FROM tool_calls WHERE session_id = :'S_OK'
      AND created_at > now() - interval '1200 seconds'), 2);

\echo '=== quiet asserts (the false-positive proofs; got must be 0) ==='
INSERT INTO tw_quiet_asserts (check_name, got) VALUES
  -- the clean LIVE session: silent across EVERY session-keyed predicate,
  -- its phase (empty storm), and its quest (rotation)
  ('clean_live_session_silent_on_all_predicates',
   (SELECT count(*) FROM tw_wedge      WHERE session_id = :'S_OK')
 + (SELECT count(*) FROM tw_slowstall  WHERE session_id = :'S_OK')
 + (SELECT count(*) FROM tw_size_ceiling WHERE session_id = :'S_OK')
 + (SELECT count(*) FROM tw_churn      WHERE session_id = :'S_OK')
 + (SELECT count(*) FROM tw_repetition WHERE session_id = :'S_OK')
 + (SELECT count(*) FROM tw_missing_spend WHERE session_id = :'S_OK')
 + (SELECT count(*) FROM tw_cache_wall WHERE session_id = :'S_OK')
 + (SELECT count(*) FROM tw_shape_storm WHERE session_id = :'S_OK')
 + (SELECT count(*) FROM tw_empty_storm WHERE phase_id = :'P_DES6')
 + (SELECT count(*) FROM tw_rotation   WHERE quest_id = :'Q6')),
  -- the clean ENDED session (incl. its legal retry pair + cached
  -- high-context turn: the repetition and cache-wall false-positive proofs)
  ('clean_ended_session_silent_on_all_predicates',
   (SELECT count(*) FROM tw_wedge      WHERE session_id = :'S_SMALL')
 + (SELECT count(*) FROM tw_slowstall  WHERE session_id = :'S_SMALL')
 + (SELECT count(*) FROM tw_size_ceiling WHERE session_id = :'S_SMALL')
 + (SELECT count(*) FROM tw_churn      WHERE session_id = :'S_SMALL')
 + (SELECT count(*) FROM tw_repetition WHERE session_id = :'S_SMALL')
 + (SELECT count(*) FROM tw_missing_spend WHERE session_id = :'S_SMALL')
 + (SELECT count(*) FROM tw_cache_wall WHERE session_id = :'S_SMALL')
 + (SELECT count(*) FROM tw_shape_storm WHERE session_id = :'S_SMALL')),
  -- threshold discrimination: 3-failure runs (replay loop, unknown-tool
  -- storm) are NOT churn — only a >= 10 run is; pins the churn threshold
  ('three_failure_runs_are_not_churn',
   (SELECT count(*) FROM tw_churn WHERE session_id IN (:'S_REPLAY', :'S_SHAPE'))),
  -- signal distinctness: the frozen session is NOT slowstall (no flow);
  -- the flowing sessions are NOT wedge
  ('stall_session_not_misread_as_slowstall',
   (SELECT count(*) FROM tw_slowstall WHERE session_id = :'S_WEDGE')),
  ('flowing_sessions_not_misread_as_wedge',
   (SELECT count(*) FROM tw_wedge WHERE session_id IN (:'S_TRICK'))),
  -- the one-empty-completion retry is normal life, not a storm
  ('isolated_empty_completion_is_not_a_storm',
   (SELECT count(*) FROM tw_empty_storm WHERE phase_id = :'P_DES6')),
  -- judge F3 count-axis near-misses: TWO empties / TWO unknown-tool /
  -- TWO non-sliced-read / TWO uncacheable-turns are all NOT storms —
  -- each count sits exactly one under its threshold, so any 3->2
  -- threshold mutation makes the counter-case fire and the gate bites
  ('two_empties_are_not_a_storm',
   (SELECT count(*) FROM tw_empty_storm WHERE phase_id = :'P_DES8')),
  ('two_shape_errors_are_not_a_storm',
   (SELECT count(*) FROM tw_shape_storm WHERE session_id = :'S_NEAR')),
  ('two_refused_reads_are_not_a_blowout',
   (SELECT count(*) FROM tw_context_blowout WHERE session_id = :'S_NEAR')),
  ('two_uncacheable_turns_are_not_a_wall',
   (SELECT count(*) FROM tw_cache_wall WHERE session_id = :'S_NEAR')),
  -- the just-under-wall turn pins the input threshold downward
  ('just_under_wall_turn_is_quiet',
   (SELECT count(*) FROM tw_cache_wall WHERE session_id = :'S_NEAR')),
  -- the beyond-cap quest's own completed first phase stays quiet
  ('rotation_ignores_within_cap_phases',
   (SELECT count(*) FROM tw_rotation WHERE quest_id IN (:'Q1', :'Q3', :'Q7'))),
  -- hub divergence quiet side: same-type and untyped coexistence never fire
  ('clean_coexistence_texts_not_divergent',
   (SELECT count(*) FROM tw_hub_divergence WHERE user_id = :'U9'
      AND canonical_text IN (
        'Fixture clean coexistence text: two quests, same terminal type, no divergence.',
        'Fixture unterminated coexistence text: typed in one quest, open in another.'))),
  -- the post-mutation pin stays fresh
  ('rv2_pin_stays_fresh',
   (SELECT count(*) FROM tw_fingerprint_drift WHERE report_version_id = :'RV2')),
  -- Q7 has no report versions: its report leg is quiet (archive leg only)
  ('q7_report_leg_quiet',
   (SELECT count(*) FROM tw_fingerprint_drift WHERE quest_id = :'Q7' AND pin_kind = 'report_pin'));

SELECT * FROM tw_fire_asserts ORDER BY check_name;
SELECT * FROM tw_quiet_asserts ORDER BY check_name;

-- abort the whole load if any assert fails (I01 seed idiom)
ALTER TABLE tw_fire_asserts  ADD CONSTRAINT ck_tw_fire  CHECK (got = want);
ALTER TABLE tw_quiet_asserts ADD CONSTRAINT ck_tw_quiet CHECK (got = 0);

COMMIT;
