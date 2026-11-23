#!/usr/bin/env bash
# ============================================================================
# kquest I03 retrieval — check-constraints.sh (gate: constraints-bite, AC4)
# ----------------------------------------------------------------------------
# Applies I01 schema+seed, I02 schema+seed, then schema-i03+seed-i03 to a
# scratch database and runs negative probes of the NEW laws. Each probe
# VIOLATES a schema-expressible law and MUST be refused by a specific named
# CHECK / FK / UNIQUE constraint (or, for the dims probe, by the generated
# column TYPE itself); a probe passes only when psql exits nonzero AND the
# expected constraint name (or error text) appears in the error. A positive
# control proves the battery is live. Exit 0 only if the control succeeds
# and every probe is refused.
#
# NEW LAWS THAT ARE NOT SCHEMA-EXPRESSIBLE, with their named enforcement
# points (DESIGN.md §11 constraint catalog):
#   N1 read-side per-user scoping (queries filter user_id; tenancy is a
#      property of the query object) -> demonstrated by the cross-user
#      probes in queries-i03.sql (families a3/b/d4); enforced at the query
#      seam (ENTRY 8 storage seam; ENTRY 5 retrieval tools R-054).
#   N2 NEW embed jobs against a RETIRED model -> pipeline job admission
#      (job runner checks registry status before creating a job; catalog
#      J-RET). Job LEDGER rows deliberately survive a retire (history);
#      only the vector tables' status pins gate the flip (probe E07).
#   N3 the retire op sequence (drain live jobs -> DROP TABLE -> flip
#      status; table_name bookkeeping) -> retire op transaction, ENTRY 8
#      job runner; schema enforces the OUTCOME (E07/E15).
#   N4 dedup threshold + top-k policy (cosine floor, candidate count) ->
#      tool-layer config, calibrated against a real registry model (ENTRY 5
#      R-036; fixture thresholds are methodology-limited, DR-15).
#   N5 batch slicing per fast-embeddings call (batch_max_texts /
#      input_max_chars from the registry row) -> job runner slicing, ENTRY 8.
#   N6 RRF constants (K=60, weights) + deterministic rank tiebreaks ->
#      queries-i03.sql owns the SQL; ENTRY 8 wraps it as a named query
#      object (the storage seam, D2).
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
I01_DIR="$SCRIPT_DIR/../../I01-core-model/artifacts"
I02_DIR="$SCRIPT_DIR/../../I02-cross-quest/artifacts"
DB="kquest_i03_probe"

if command -v psql >/dev/null 2>&1; then
  PSQL="psql"
else
  PSQL="/opt/homebrew/bin/psql"
fi

ALICE='00000000-0000-4000-8000-000000000001'
BOB='00000000-0000-4000-8000-000000000002'
QA='b0000000-0000-4000-8000-000000000001'
M1='92000000-0000-4000-8000-000000000001'     # registry: active dense fixture
M3='92000000-0000-4000-8000-000000000003'     # registry: RETIRED
K1='f0000000-0000-4000-8000-000000000001'     # alice claim (quest A)
CH1='00000000-0000-4000-8000-0000000000aa'    # probe chunk (registered below)
UE1='70000000-0000-4000-8000-000000000021'    # alice usage event (I03 seed)
UE_BOB='70000000-0000-4000-8000-000000000028' # BOB usage event (I03 seed)
PROBE_MODEL='92000000-0000-4000-8000-0000000000e1'  # E07/E08 probe model

FAILED=0
PASSED=0

"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1
"$PSQL" -q -d postgres -c "CREATE DATABASE $DB" >/dev/null 2>&1 || { echo "FAIL: create db"; exit 1; }
"$PSQL" -q -d "$DB" -c "CREATE EXTENSION vector" >/dev/null 2>&1 \
  || { echo "FAIL: CREATE EXTENSION vector"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I01_DIR/schema.sql" >/dev/null 2>&1 \
  || { echo "FAIL: I01 schema.sql"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I01_DIR/seed.sql" >/dev/null 2>&1 \
  || { echo "FAIL: I01 seed.sql"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I02_DIR/schema-i02.sql" >/dev/null 2>&1 \
  || { echo "FAIL: schema-i02.sql"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I02_DIR/seed-i02.sql" >/dev/null 2>&1 \
  || { echo "FAIL: seed-i02.sql"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$SCRIPT_DIR/schema-i03.sql" >/dev/null 2>&1 \
  || { echo "FAIL: schema-i03.sql"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$SCRIPT_DIR/seed-i03.sql" >/dev/null 2>&1 \
  || { echo "FAIL: seed-i03.sql"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }

probe() {
  name="$1"; expect="$2"; sql="$3"
  out="$("$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" 2>&1 <<< "$sql")"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL  $name — ACCEPTED (expected refusal by $expect)"
    FAILED=$((FAILED+1))
  elif echo "$out" | grep -q "$expect"; then
    echo "pass  $name — refused by $expect"
    PASSED=$((PASSED+1))
  else
    echo "FAIL  $name — refused, but not by $expect:"
    echo "$out" | sed 's/^/      /' | head -3
    FAILED=$((FAILED+1))
  fi
}

echo "== positive control: a legal pipeline run MUST be accepted =="
# registration as a DATA operation (a brand-new model row + its generated
# table + one embed job + one vector) — the register/retire/A-B flow, live.
if out=$("$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" <<SQL
INSERT INTO embedding_models (id, slug, wire_name, provider, endpoint, dimensions, metric, table_name)
VALUES ('$PROBE_MODEL', 'probe-mod-64', 'probe/mod-64', 'tei-local',
        'http://tei-local.example/v1/embeddings', 64, 'cosine', 'emb_probe_mod_64');
CREATE TABLE emb_probe_mod_64 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_id uuid NOT NULL CONSTRAINT ck_emb_probe_mod_64_model CHECK (model_id = '$PROBE_MODEL'),
  model_status text NOT NULL CONSTRAINT ck_emb_probe_mod_64_status CHECK (model_status = 'active'),
  user_id uuid NOT NULL, target_kind text NOT NULL
    CONSTRAINT ck_emb_probe_mod_64_kind CHECK (target_kind IN ('chunk', 'claim', 'frontier_need')),
  chunk_id uuid, claim_id uuid, need_id uuid,
  embedding vector(64) NOT NULL,
  embedded_text text NOT NULL, job_id uuid NOT NULL,
  CONSTRAINT ck_emb_probe_mod_64_target_exactly_one
    CHECK ((chunk_id IS NOT NULL)::int + (claim_id IS NOT NULL)::int + (need_id IS NOT NULL)::int = 1),
  CONSTRAINT uq_emb_probe_mod_64_target UNIQUE NULLS NOT DISTINCT (target_kind, chunk_id, claim_id, need_id),
  CONSTRAINT uq_emb_probe_mod_64_id_user UNIQUE (id, user_id),
  CONSTRAINT fk_emb_probe_mod_64_model FOREIGN KEY (model_id, model_status)
    REFERENCES embedding_models (id, status),
  CONSTRAINT fk_emb_probe_mod_64_job FOREIGN KEY (job_id, user_id) REFERENCES embed_jobs (id, user_id),
  CONSTRAINT fk_emb_probe_mod_64_chunk FOREIGN KEY (chunk_id, user_id) REFERENCES chunks (id, user_id),
  CONSTRAINT fk_emb_probe_mod_64_claim FOREIGN KEY (claim_id, user_id) REFERENCES claims (id, user_id),
  CONSTRAINT fk_emb_probe_mod_64_need FOREIGN KEY (need_id, user_id) REFERENCES frontier_entries (id, user_id)
);
CREATE INDEX idx_emb_probe_mod_64_hnsw ON emb_probe_mod_64 USING hnsw (embedding vector_cosine_ops);
INSERT INTO embed_jobs (id, user_id, quest_id, phase_id, kind, model_id, target_kind, state, idem_key, total_items, done_items, started_at, ended_at, usage_event_id)
VALUES ('91000000-0000-4000-8000-0000000000e1', '$ALICE', '$QA',
        'd0000000-0000-4000-8000-000000000002', 'embed', '$PROBE_MODEL', 'claim',
        'complete', 'embed:$PROBE_MODEL:claim:quest:$QA', 1, 1, now(), now(), '$UE1');
INSERT INTO emb_probe_mod_64 (model_id, model_status, user_id, target_kind, claim_id, embedding, embedded_text, job_id)
VALUES ('$PROBE_MODEL', 'active', '$ALICE', 'claim', '$K1',
        ('[' || array_to_string(array_fill(0.25, ARRAY[64]), ',') || ']')::vector,
        (SELECT canonical_text FROM claims WHERE id = '$K1'),
        '91000000-0000-4000-8000-0000000000e1');
SQL
); then
  echo "pass  control — register + generate table + embed job + spend-linked vector accepted (registration is data; completed⇒spend is the amended J-SPEND law)"
  PASSED=$((PASSED+1))
else
  echo "FAIL  control — legal pipeline run refused (environment or schema broken):"
  echo "$out" | sed 's/^/      /'
  FAILED=$((FAILED+1))
fi

echo "== negative probes (each must be refused by its named constraint) =="

# ---- registry-only law (D4) ----
probe "E01 embed job naming a model NOT in the registry" \
  "fk_embed_jobs_model" \
  "INSERT INTO embed_jobs (user_id, quest_id, phase_id, kind, model_id, target_kind, state, idem_key, total_items, done_items, started_at, ended_at, usage_event_id)
   VALUES ('$ALICE', '$QA', 'd0000000-0000-4000-8000-000000000002', 'embed', gen_random_uuid(), 'claim',
           'complete', 'embed:bogus:claim:quest:$QA', 1, 1, now(), now(), '$UE1');"

probe "E02 embed job with NO model at all (kind=embed must name one)" \
  "ck_embed_jobs_model_pair" \
  "INSERT INTO embed_jobs (user_id, quest_id, phase_id, kind, target_kind, state, idem_key, total_items, done_items, started_at, ended_at, usage_event_id)
   VALUES ('$ALICE', '$QA', 'd0000000-0000-4000-8000-000000000002', 'embed', 'claim',
           'complete', 'embed:none:claim:quest:$QA', 1, 1, now(), now(), '$UE1');"

# ---- job lifecycle laws ----
probe "E03 duplicate LIVE job with the same idem_key (idempotency)" \
  "uq_embed_jobs_idem_active" \
  "INSERT INTO embed_jobs (user_id, quest_id, phase_id, kind, model_id, target_kind, state, idem_key, total_items, done_items, started_at)
   VALUES ('$ALICE', '$QA', 'd0000000-0000-4000-8000-000000000002', 'embed', '$M1', 'claim',
           'pending', 'embed:$M1:claim:quest:$QA', 1, 0, NULL);"

probe "E04 COMPLETED job whose cursor never reached the total (completion tampering)" \
  "ck_embed_jobs_complete_terminal" \
  "INSERT INTO embed_jobs (user_id, quest_id, phase_id, kind, model_id, target_kind, state, idem_key, total_items, done_items, started_at, ended_at, usage_event_id)
   VALUES ('$ALICE', '$QA', 'd0000000-0000-4000-8000-000000000002', 'embed', '$M1', 'chunk',
           'complete', 'embed:$M1:chunk:tamper', 10, 6, now(), now(), '$UE1');"

probe "E05 progress cursor beyond the total" \
  "ck_embed_jobs_progress" \
  "UPDATE embed_jobs SET done_items = total_items + 1
   WHERE id = '91000000-0000-4000-8000-000000000006';"

probe "E06 FAILED job without an error note (failure is explained)" \
  "ck_embed_jobs_error_pair" \
  "INSERT INTO embed_jobs (user_id, quest_id, phase_id, kind, model_id, target_kind, state, idem_key, total_items, done_items, started_at, ended_at)
   VALUES ('$ALICE', '$QA', 'd0000000-0000-4000-8000-000000000002', 'embed', '$M1', 'claim',
           'failed', 'embed:$M1:claim:quest:unexplained', 8, 0, now(), now());"

probe "E08 spend linked to a job that is not a COMPLETED embed job" \
  "ck_embed_jobs_usage_kind" \
  "UPDATE embed_jobs SET usage_event_id = '$UE1'
   WHERE id = '91000000-0000-4000-8000-000000000014';"

probe "E21 COMPLETED embed job with NO spend link (the completed=>spend direction, judge F1)" \
  "ck_embed_jobs_complete_spend" \
  "INSERT INTO embed_jobs (user_id, quest_id, phase_id, kind, model_id, target_kind, state, idem_key, total_items, done_items, started_at, ended_at)
   VALUES ('$ALICE', '$QA', 'd0000000-0000-4000-8000-000000000002', 'embed', '$M1', 'claim',
           'complete', 'embed:$M1:claim:quest:nospend', 1, 1, now(), now());"

probe "E22 chunk-family embed job with NO quest (corpus backfills are per-quest jobs — DR-06 ruled A, 2026-11-22)" \
  "ck_embed_jobs_scope" \
  "INSERT INTO embed_jobs (user_id, quest_id, phase_id, kind, model_id, target_kind, strategy_id, state, idem_key, total_items, done_items, started_at, ended_at, usage_event_id)
   VALUES ('$ALICE', NULL, NULL, 'embed', '$M1', 'chunk', 'c0000000-0000-4000-8000-000000000001',
           'complete', 'embed:$M1:chunk:orphan', 1, 1, now(), now(), '$UE1');"

probe "E19 embed job carrying a chunk-strategy while targeting claims" \
  "ck_embed_jobs_strategy_scope" \
  "INSERT INTO embed_jobs (user_id, quest_id, phase_id, kind, model_id, target_kind, strategy_id, state, idem_key, total_items, done_items, started_at, ended_at, usage_event_id)
   VALUES ('$ALICE', '$QA', 'd0000000-0000-4000-8000-000000000002', 'embed', '$M1', 'claim',
           'c0000000-0000-4000-8000-000000000001', 'complete', 'embed:$M1:claim:strategy-misuse', 1, 1, now(), now(), '$UE1');"

probe "E20 job that ends before it starts" \
  "ck_embed_jobs_times" \
  "INSERT INTO embed_jobs (user_id, quest_id, phase_id, kind, model_id, target_kind, state, idem_key, total_items, done_items, started_at, ended_at, error_note)
   VALUES ('$ALICE', '$QA', 'd0000000-0000-4000-8000-000000000002', 'embed', '$M1', 'claim',
           'failed', 'embed:$M1:claim:quest:timewarp', 8, 0, now(), now() - interval '1 hour', 'explained');"

# ---- the retire law (DR-04) ----
probe "E07 RETIRING a model while its vectors pin 'active' (live table)" \
  "fk_emb_probe_mod_64_model" \
  "UPDATE embedding_models SET status = 'retired', retired_at = now() WHERE id = '$PROBE_MODEL';"

probe "E15 retire flip without the retire timestamp (pair law)" \
  "ck_embedding_models_retire_pair" \
  "UPDATE embedding_models SET status = 'retired' WHERE id = '$M1';"

probe "E16 registry row with zero dimensions" \
  "ck_embedding_models_dims" \
  "INSERT INTO embedding_models (slug, wire_name, provider, endpoint, dimensions, metric, table_name)
   VALUES ('zero-d', 'zero/d', 'tei-local', 'http://t.example/v1', 0, 'cosine', 'emb_zero_d');"

probe "E17 registration whose table name violates the generated-name law" \
  "ck_embedding_models_slug_table" \
  "INSERT INTO embedding_models (slug, wire_name, provider, endpoint, dimensions, metric, table_name)
   VALUES ('mismatch', 'mis/match', 'tei-local', 'http://t.example/v1', 64, 'cosine', 'emb_something_else');"

# ---- generated-table vector laws ----
probe "E09 wrong-dims vector (384) into the 1024d generated table" \
  "expected 1024 dimensions" \
  "INSERT INTO emb_bge_m3_1024 (model_id, model_status, user_id, target_kind, claim_id, embedding, embedded_text, job_id)
   VALUES ('$M1', 'active', '$ALICE', 'claim', '$K1',
           ('[' || array_to_string(array_fill(0.25, ARRAY[384]), ',') || ']')::vector,
           'probe', '91000000-0000-4000-8000-000000000007');"

probe "E10 target_kind names a forbidden kind (evidence readings are NOT targets)" \
  "ck_emb_bge_m3_1024_kind" \
  "INSERT INTO emb_bge_m3_1024 (model_id, model_status, user_id, target_kind, claim_id, embedding, embedded_text, job_id)
   VALUES ('$M1', 'active', '$ALICE', 'evidence_reading', '$K1',
           (SELECT embedding FROM emb_bge_m3_1024 LIMIT 1), 'probe', '91000000-0000-4000-8000-000000000007');"

probe "E11 kind/column mismatch (target_kind=chunk but a claim column set)" \
  "ck_emb_bge_m3_1024_target_matches_kind" \
  "INSERT INTO emb_bge_m3_1024 (model_id, model_status, user_id, target_kind, claim_id, embedding, embedded_text, job_id)
   VALUES ('$M1', 'active', '$ALICE', 'chunk', '$K1',
           (SELECT embedding FROM emb_bge_m3_1024 LIMIT 1), 'probe', '91000000-0000-4000-8000-000000000007');"

probe "E12 two target columns set at once" \
  "ck_emb_bge_m3_1024_target_exactly_one" \
  "INSERT INTO emb_bge_m3_1024 (model_id, model_status, user_id, target_kind, claim_id, need_id, embedding, embedded_text, job_id)
   VALUES ('$M1', 'active', '$ALICE', 'claim', '$K1', '40000000-0000-4000-8000-000000000001',
           (SELECT embedding FROM emb_bge_m3_1024 LIMIT 1), 'probe', '91000000-0000-4000-8000-000000000007');"

probe "E13 CROSS-USER vector row (bob's tenancy pinning alice's chunk)" \
  "fk_emb_bge_m3_1024_chunk" \
  "INSERT INTO emb_bge_m3_1024 (model_id, model_status, user_id, target_kind, chunk_id, embedding, embedded_text, job_id)
   SELECT '$M1', 'active', '$BOB', 'chunk', c.id,
          (SELECT embedding FROM emb_bge_m3_1024 LIMIT 1), c.text,
          '91000000-0000-4000-8000-000000000016'
   FROM chunks c JOIN chunk_strategies cs ON cs.id = c.strategy_id
   WHERE cs.name = 'para-400' AND c.ordinal > 2 AND c.user_id = '$ALICE' LIMIT 1;"

probe "E14 second vector for the SAME (model, target) — re-embed must REPLACE" \
  "uq_emb_bge_m3_1024_target" \
  "INSERT INTO emb_bge_m3_1024 (model_id, model_status, user_id, target_kind, claim_id, embedding, embedded_text, job_id)
   SELECT '$M1', 'active', user_id, 'claim', claim_id, embedding, embedded_text, job_id
   FROM emb_bge_m3_1024 WHERE target_kind = 'claim' LIMIT 1;"

probe "E18 job linking ANOTHER USER's usage event (spend tenancy)" \
  "fk_embed_jobs_usage" \
  "UPDATE embed_jobs SET usage_event_id = '$UE_BOB'
   WHERE id = '91000000-0000-4000-8000-000000000007';"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "check-constraints: PASS ($((PASSED-1)) negative probes + 1 positive control)"
  RC=0
else
  echo "check-constraints: FAIL ($FAILED failed, $PASSED passed)"
  RC=1
fi
"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1
exit $RC
