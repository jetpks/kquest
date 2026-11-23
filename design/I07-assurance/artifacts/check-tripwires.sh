#!/usr/bin/env bash
# ============================================================================
# kquest I07 assurance — check-tripwires.sh (gate: tripwires-execute, AC2)
# ----------------------------------------------------------------------------
# Scratch db kquest_i07_trip (drop-if-exists, always cleaned up):
#   1. I01 schema + seed           (frozen law, read-only)
#   2. I02 schema + seed           (frozen law — the divergence/fingerprint
#                                   predicates query v_canonical_claims,
#                                   v_quest_graph_fingerprint, report pins)
#   3. tripwires-i07.sql           (fixtures + tw_* views + self-verification
#                                   asserts; ON_ERROR_STOP aborts on any
#                                   fire/quiet assert failure)
#   4. tripwires-i07.sql AGAIN     (idempotency proof: fixed-id ON CONFLICT
#                                   fixtures + CREATE OR REPLACE views)
#   5. predicate inventory        (per-predicate global + fixture-tenant
#                                   counts, printed as the fire/quiet table)
# Drop. Exit 0 only on full success. Runs from any cwd (paths relative to
# this script). plpgsql-free. Outputs to files; never pipes psql through
# head. macOS bash 3.2 safe.
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
I01_DIR="$SCRIPT_DIR/../../I01-core-model/artifacts"
I02_DIR="$SCRIPT_DIR/../../I02-cross-quest/artifacts"
DB="kquest_i07_trip"
OUT="$(mktemp -d /tmp/kquest_i07_tw.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

if command -v psql >/dev/null 2>&1; then
  PSQL="psql"
else
  PSQL="/opt/homebrew/bin/psql"
fi

cleanup() { "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB" 2>/dev/null; }
fail_drop() { echo "FAIL: $1"; cleanup; exit 1; }

echo "== check-tripwires: scratch database $DB =="
"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB" || { echo "FAIL: drop stale db"; exit 1; }
"$PSQL" -q -d postgres -c "CREATE DATABASE $DB" || { echo "FAIL: create scratch db"; exit 1; }
"$PSQL" -q -d "$DB" -c "CREATE EXTENSION vector" || fail_drop "CREATE EXTENSION vector"

rc=0
echo "== applying I01 schema.sql + seed.sql (read-only law) =="
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I01_DIR/schema.sql" >"$OUT/i01_schema.log" 2>&1 || { rc=1; tail -5 "$OUT/i01_schema.log"; }
[ $rc -eq 0 ] && "$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I01_DIR/seed.sql" >"$OUT/i01_seed.log" 2>&1 || { rc=1; tail -5 "$OUT/i01_seed.log"; }

if [ $rc -eq 0 ]; then
  echo "== applying I02 schema-i02.sql + seed-i02.sql (read-only law) =="
  "$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I02_DIR/schema-i02.sql" >"$OUT/i02_schema.log" 2>&1 || { rc=1; tail -5 "$OUT/i02_schema.log"; }
  [ $rc -eq 0 ] && "$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I02_DIR/seed-i02.sql" >"$OUT/i02_seed.log" 2>&1 || { rc=1; tail -5 "$OUT/i02_seed.log"; }
fi

if [ $rc -eq 0 ]; then
  echo "== applying tripwires-i07.sql (fixtures + views + self-verify asserts) =="
  "$PSQL" -v ON_ERROR_STOP=1 -d "$DB" -f "$SCRIPT_DIR/tripwires-i07.sql" >"$OUT/tw_apply1.log" 2>&1
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "FAIL: tripwires-i07.sql apply/assert failed (transcript tail):"
    tail -15 "$OUT/tw_apply1.log" | sed 's/^/      /'
  else
    grep -E '^[[:space:]]+[a-z_0-9]+[[:space:]]+\|' "$OUT/tw_apply1.log" | head -60 > "$OUT/assert_rows.log" || true
    echo "pass  fire+quiet self-verification asserts passed (see $OUT/tw_apply1.log)"
  fi
fi

if [ $rc -eq 0 ]; then
  echo "== idempotency: applying tripwires-i07.sql a second time =="
  "$PSQL" -v ON_ERROR_STOP=1 -d "$DB" -f "$SCRIPT_DIR/tripwires-i07.sql" >"$OUT/tw_apply2.log" 2>&1
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "FAIL: second apply is not idempotent (transcript tail):"
    tail -15 "$OUT/tw_apply2.log" | sed 's/^/      /'
  else
    echo "pass  re-apply clean (fixed-id fixtures + CREATE OR REPLACE views)"
  fi
fi

if [ $rc -eq 0 ]; then
  echo "== predicate inventory: every tw_* view, global + fixture-tenant counts =="
  # one row per predicate: name, global rows, rows scoped to the fixture
  # tenant (user 00000000-0000-4000-8000-000000000009), and the quiet proof
  # (clean fixtures S_OK 79000000-...-11 / S_SMALL ...-08 appear in NO view)
  "$PSQL" -v ON_ERROR_STOP=1 -d "$DB" >"$OUT/inventory.log" 2>&1 <<'SQL' || rc=1
\pset pager off
WITH inv AS (
  SELECT 'tw_wedge' AS tw, count(*) AS global_rows,
         count(*) FILTER (WHERE user_id = '00000000-0000-4000-8000-000000000009') AS fixture_rows,
         count(*) FILTER (WHERE session_id IN ('79000000-0000-4000-8000-000000000011',
                                               '79000000-0000-4000-8000-000000000008')) AS clean_rows
    FROM tw_wedge
  UNION ALL
  SELECT 'tw_slowstall', count(*),
         count(*) FILTER (WHERE user_id = '00000000-0000-4000-8000-000000000009'),
         count(*) FILTER (WHERE session_id IN ('79000000-0000-4000-8000-000000000011',
                                               '79000000-0000-4000-8000-000000000008'))
    FROM tw_slowstall
  UNION ALL
  SELECT 'tw_size_ceiling', count(*),
         count(*) FILTER (WHERE user_id = '00000000-0000-4000-8000-000000000009'),
         count(*) FILTER (WHERE session_id IN ('79000000-0000-4000-8000-000000000011',
                                               '79000000-0000-4000-8000-000000000008'))
    FROM tw_size_ceiling
  UNION ALL
  SELECT 'tw_churn', count(*),
         count(*) FILTER (WHERE session_id IN ('79000000-0000-4000-8000-000000000002')),
         count(*) FILTER (WHERE session_id IN ('79000000-0000-4000-8000-000000000011',
                                               '79000000-0000-4000-8000-000000000008'))
    FROM tw_churn
  UNION ALL
  SELECT 'tw_rotation', count(*),
         count(*) FILTER (WHERE user_id = '00000000-0000-4000-8000-000000000009'),
         count(*) FILTER (WHERE quest_id IN ('77000000-0000-4000-8000-000000000006'))
    FROM tw_rotation
  UNION ALL
  SELECT 'tw_empty_storm', count(*),
         count(*) FILTER (WHERE user_id = '00000000-0000-4000-8000-000000000009'),
         count(*) FILTER (WHERE phase_id IN ('78000000-0000-4000-8000-000000000006'))
    FROM tw_empty_storm
  UNION ALL
  SELECT 'tw_repetition', count(*),
         count(*) FILTER (WHERE session_id IN ('79000000-0000-4000-8000-000000000003')),
         count(*) FILTER (WHERE session_id IN ('79000000-0000-4000-8000-000000000011',
                                               '79000000-0000-4000-8000-000000000008'))
    FROM tw_repetition
  UNION ALL
  SELECT 'tw_missing_spend', count(*),
         count(*) FILTER (WHERE user_id = '00000000-0000-4000-8000-000000000009'),
         count(*) FILTER (WHERE session_id IN ('79000000-0000-4000-8000-000000000011',
                                               '79000000-0000-4000-8000-000000000008'))
    FROM tw_missing_spend
  UNION ALL
  SELECT 'tw_cache_wall', count(*),
         count(*) FILTER (WHERE session_id IN ('79000000-0000-4000-8000-000000000006')),
         count(*) FILTER (WHERE session_id IN ('79000000-0000-4000-8000-000000000011',
                                               '79000000-0000-4000-8000-000000000008'))
    FROM tw_cache_wall
  UNION ALL
  SELECT 'tw_shape_storm', count(*),
         count(*) FILTER (WHERE session_id IN ('79000000-0000-4000-8000-000000000007')),
         count(*) FILTER (WHERE session_id IN ('79000000-0000-4000-8000-000000000011',
                                               '79000000-0000-4000-8000-000000000008'))
    FROM tw_shape_storm
  UNION ALL
  SELECT 'tw_hub_divergence', count(*),
         count(*) FILTER (WHERE user_id = '00000000-0000-4000-8000-000000000009'),
         count(*) FILTER (WHERE canonical_text IN (
           'Fixture clean coexistence text: two quests, same terminal type, no divergence.',
           'Fixture unterminated coexistence text: typed in one quest, open in another.'))
    FROM tw_hub_divergence
  UNION ALL
  SELECT 'tw_fingerprint_drift', count(*),
         count(*) FILTER (WHERE user_id = '00000000-0000-4000-8000-000000000009'),
         count(*) FILTER (WHERE report_version_id = '7e000000-0000-4000-8000-000000000002')
    FROM tw_fingerprint_drift
  UNION ALL
  SELECT 'tw_context_blowout', count(*),
         count(*) FILTER (WHERE session_id IN ('79000000-0000-4000-8000-000000000014')),
         count(*) FILTER (WHERE session_id IN ('79000000-0000-4000-8000-000000000013'))
    FROM tw_context_blowout
)
SELECT tw AS predicate, global_rows, fixture_rows, clean_rows,
       CASE WHEN fixture_rows >= 1 THEN 'FIRES' ELSE 'QUIET' END AS verdict
FROM inv
ORDER BY tw;
SQL
  cat "$OUT/inventory.log"
  # every predicate must FIRE on its fixture; every clean count must be 0
  # (rows: predicate | global_rows | fixture_rows | clean_rows | verdict)
  fires=$(awk -F'|' 'NR>2 { gsub(/[[:space:]]/, "", $5); if ($5 == "FIRES") n++ } END { print n+0 }' "$OUT/inventory.log")
  if [ "$fires" -eq 13 ]; then
    echo "pass  all 13 predicates FIRE on their fixtures"
  else
    echo "FAIL  expected 13 FIRES verdicts, saw $fires"
    rc=1
  fi
  # the clean columns: any nonzero clean_rows cell is a false positive
  if awk -F'|' 'NR>2 { gsub(/[[:space:]]/, "", $4); if ($4 != "" && $4+0 > 0) exit 1 }' "$OUT/inventory.log"; then
    echo "pass  clean fixtures appear in zero predicates (no false positives)"
  else
    echo "FAIL  a clean fixture row appeared in a predicate (false positive)"
    rc=1
  fi
fi

echo "== dropping scratch database $DB =="
"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"

if [ $rc -eq 0 ]; then
  echo "check-tripwires: PASS"
  exit 0
else
  echo "check-tripwires: FAIL"
  exit 1
fi
