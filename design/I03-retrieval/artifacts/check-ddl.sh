#!/usr/bin/env bash
# ============================================================================
# kquest I03 retrieval — check-ddl.sh (gate: ddl-runs, AC2)
# ----------------------------------------------------------------------------
# Creates scratch db kquest_i03_check (drop-if-exists), then applies in
# order (I01/I02 are READ-ONLY law; paths relative to this script):
#   1. design/I01-core-model/artifacts/schema.sql   + seed.sql
#   2. design/I02-cross-quest/artifacts/schema-i02.sql + seed-i02.sql
#   3. design/I03-retrieval/artifacts/schema-i03.sql + seed-i03.sql
# then asserts the I03 seed-contract minimums (Specification, output format)
# and drops the db. Exit 0 only on full success.
#
# R-035 DISCHARGE: this gate re-proves pgvector on the local Postgres —
# CREATE EXTENSION vector must succeed and the INSTALLED VERSION is recorded
# in this script's output (verified fact: 0.8.7 available on this machine).
#
# plpgsql-free (assert = temp table + CHECK constraint, the I01 idiom).
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
I01_DIR="$SCRIPT_DIR/../../I01-core-model/artifacts"
I02_DIR="$SCRIPT_DIR/../../I02-cross-quest/artifacts"
DB="kquest_i03_check"

if command -v psql >/dev/null 2>&1; then
  PSQL="psql"
else
  PSQL="/opt/homebrew/bin/psql"
fi

echo "== check-ddl: scratch database $DB =="
rc=0

"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB" || { echo "FAIL: drop stale db"; exit 1; }
"$PSQL" -q -d postgres -c "CREATE DATABASE $DB" || { echo "FAIL: create scratch db"; exit 1; }

echo "== R-035: verify pgvector extension and RECORD the version =="
if ! "$PSQL" -q -d "$DB" -c "CREATE EXTENSION vector"; then
  echo "FAIL: CREATE EXTENSION vector (pgvector not available)"
  "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"
  exit 1
fi
PGVECTOR_VERSION="$("$PSQL" -At -d "$DB" -c "SELECT extversion FROM pg_extension WHERE extname = 'vector'")"
if [ -z "$PGVECTOR_VERSION" ]; then
  echo "FAIL: pgvector installed version not readable"
  "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"
  exit 1
fi
echo "pgvector installed version: $PGVECTOR_VERSION (R-035 discharged: CREATE EXTENSION vector verified working)"

echo "== applying I01 schema.sql + seed.sql (read-only law) =="
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I01_DIR/schema.sql" || rc=1
if [ $rc -eq 0 ]; then "$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I01_DIR/seed.sql" || rc=1; fi

echo "== applying I02 schema-i02.sql + seed-i02.sql (read-only law) =="
if [ $rc -eq 0 ]; then "$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I02_DIR/schema-i02.sql" || rc=1; fi
if [ $rc -eq 0 ]; then "$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I02_DIR/seed-i02.sql" || rc=1; fi

echo "== applying schema-i03.sql (additive delta) =="
if [ $rc -eq 0 ]; then "$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$SCRIPT_DIR/schema-i03.sql" || rc=1; fi

echo "== applying seed-i03.sql =="
if [ $rc -eq 0 ]; then "$PSQL" -v ON_ERROR_STOP=1 -d "$DB" -f "$SCRIPT_DIR/seed-i03.sql" || rc=1; fi

if [ $rc -eq 0 ]; then
  echo "== asserting I03 seed-contract minimums (Specification, output format) =="
  "$PSQL" -v ON_ERROR_STOP=1 -d "$DB" <<'SQL' || rc=1
CREATE TEMP TABLE ddl_asserts (check_name text PRIMARY KEY, ok boolean NOT NULL);
INSERT INTO ddl_asserts (check_name, ok) VALUES
  -- registry (R-028): >= 2 registered models; 1 active dense fixture + the
  -- A/B challenger + a retired one (register/retire/A-B as data operations)
  ('registry >= 2 models',                 (SELECT count(*) >= 2 FROM embedding_models)),
  ('registry: active dense fixture (1024d cosine)', (SELECT count(*) >= 1 FROM embedding_models
                                                     WHERE status = 'active' AND dimensions = 1024 AND metric = 'cosine')),
  ('registry: second ACTIVE model (A/B posture)', (SELECT count(*) >= 2 FROM embedding_models WHERE status = 'active')),
  ('registry: retired model present',      (SELECT count(*) >= 1 FROM embedding_models WHERE status = 'retired')),
  ('registry: wire identity unique per provider', (SELECT count(*) = count(DISTINCT (provider, wire_name)) FROM embedding_models)),
  -- generated tables (R-029): typed dims + hnsw (the generator contract)
  ('emb_bge_m3_1024.embedding is vector(1024)', (SELECT format_type(a.atttypid, a.atttypmod) = 'vector(1024)'
                                                 FROM pg_attribute a
                                                 WHERE a.attrelid = 'emb_bge_m3_1024'::regclass
                                                   AND a.attname = 'embedding' AND a.attnum > 0)),
  ('emb_minilm_ab_384.embedding is vector(384)', (SELECT format_type(a.atttypid, a.atttypmod) = 'vector(384)'
                                                 FROM pg_attribute a
                                                 WHERE a.attrelid = 'emb_minilm_ab_384'::regclass
                                                   AND a.attname = 'embedding' AND a.attnum > 0)),
  ('emb_bge_m3_1024 has an hnsw cosine index',   (SELECT count(*) >= 1 FROM pg_indexes
                                                 WHERE tablename = 'emb_bge_m3_1024'
                                                   AND indexdef ~* 'USING hnsw' AND indexdef ~* 'vector_cosine_ops')),
  ('emb_minilm_ab_384 has an hnsw cosine index', (SELECT count(*) >= 1 FROM pg_indexes
                                                 WHERE tablename = 'emb_minilm_ab_384'
                                                   AND indexdef ~* 'USING hnsw' AND indexdef ~* 'vector_cosine_ops')),
  ('retired model table ABSENT (dropped)',  (SELECT count(*) = 0 FROM embedding_models
                                             WHERE status = 'retired' AND to_regclass(table_name) IS NOT NULL)),
  ('active models have their tables',       (SELECT count(*) = 0 FROM embedding_models
                                             WHERE status = 'active' AND to_regclass(table_name) IS NULL)),
  -- jobs (R-031): every lifecycle state; idem retry pair; resumable cursor
  ('jobs: every lifecycle state present',   (SELECT count(*) = 4 FROM (SELECT DISTINCT state FROM embed_jobs) s)),
  ('jobs: fetch/chunk/embed kinds present', (SELECT count(*) = 3 FROM (SELECT DISTINCT kind FROM embed_jobs) k)),
  ('jobs: idem retry pair (failed -> complete)', (SELECT count(*) >= 1 FROM (
                                                   SELECT idem_key FROM embed_jobs
                                                   GROUP BY idem_key
                                                   HAVING count(*) FILTER (WHERE state = 'failed') >= 1
                                                      AND count(*) FILTER (WHERE state = 'complete') >= 1) r)),
  ('jobs: running job with done < total (resumable)', (SELECT count(*) >= 1 FROM embed_jobs
                                                       WHERE state = 'running' AND done_items < total_items)),
  ('jobs: one non-failed row per idem key', (SELECT count(*) = 0 FROM (
                                               SELECT idem_key FROM embed_jobs WHERE state <> 'failed'
                                               GROUP BY idem_key HAVING count(*) > 1) d)),
  -- cost accounting (D10): completed embed jobs carry embedding usage rows
  ('spend: completed embed jobs link usage rows', (SELECT count(*) >= 1 FROM embed_jobs j
                                                   WHERE j.kind = 'embed' AND j.state = 'complete'
                                                     AND j.usage_event_id IS NOT NULL)),
  ('spend: usage rows are kind embedding',  (SELECT count(*) = 0 FROM embed_jobs j
                                             JOIN usage_events u ON u.id = j.usage_event_id
                                             WHERE u.kind <> 'embedding')),
  ('spend: local-model row with NULL cost', (SELECT count(*) >= 1 FROM usage_events
                                             WHERE kind = 'embedding' AND cost_usd IS NULL)),
  -- vectors (R-030): all three target families populated; nothing else
  ('vectors: chunk family populated',       (SELECT count(*) >= 10 FROM emb_bge_m3_1024 WHERE target_kind = 'chunk')),
  ('vectors: claim family populated',       (SELECT count(*) >= 10 FROM emb_bge_m3_1024 WHERE target_kind = 'claim')),
  ('vectors: frontier_need family populated', (SELECT count(*) >= 5 FROM emb_bge_m3_1024 WHERE target_kind = 'frontier_need')),
  ('vectors: A/B model populated (claims)', (SELECT count(*) >= 5 FROM emb_minilm_ab_384 WHERE target_kind = 'claim')),
  ('vectors: tenant-B rows present (scoping fixture)', (SELECT count(*) >= 1 FROM emb_bge_m3_1024
                                                        WHERE user_id = '00000000-0000-4000-8000-000000000002')),
  ('vectors: every row pins a job',         (SELECT count(*) = 0 FROM emb_bge_m3_1024 e
                                             WHERE NOT EXISTS (SELECT 1 FROM embed_jobs j WHERE j.id = e.job_id))),
  -- FTS substrate (R-032 lexical leg)
  ('chunks.search_tsv generated + populated', (SELECT count(*) = 0 FROM chunks
                                               WHERE search_tsv IS NULL OR search_tsv = ''::tsvector)),
  ('chunks GIN index on search_tsv exists', (SELECT count(*) >= 1 FROM pg_indexes
                                             WHERE tablename = 'chunks' AND indexdef ~* 'USING gin' AND indexdef ~* 'search_tsv')),
  -- I01/I02 law survives the delta (cross-consistency)
  ('hub view still covers every claim',     (SELECT count(*) = 0 FROM claims c
                                             WHERE (SELECT count(*) FROM v_canonical_claims v
                                                    WHERE v.user_id = c.user_id
                                                      AND v.canonical_text = c.canonical_text
                                                      AND c.id = ANY (v.member_claim_ids)) <> 1)),
  ('no bare claims after I03 fixtures (L6)', (SELECT count(*) = 0 FROM v_claim_closure WHERE bare)),
  ('cross-tenant claim vectors exist for BOTH users', (SELECT count(DISTINCT user_id) = 2 FROM emb_bge_m3_1024
                                                       WHERE target_kind = 'claim'));
SELECT check_name, ok FROM ddl_asserts ORDER BY check_name;
ALTER TABLE ddl_asserts ADD CONSTRAINT ck_ddl_asserts CHECK (ok);
SQL
fi

echo "== dropping scratch database $DB =="
"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"

if [ $rc -eq 0 ]; then
  echo "check-ddl: PASS"
  exit 0
else
  echo "check-ddl: FAIL"
  exit 1
fi
