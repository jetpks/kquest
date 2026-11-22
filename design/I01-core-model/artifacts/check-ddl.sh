#!/usr/bin/env bash
# ============================================================================
# kquest I01 core-model — check-ddl.sh (gate: ddl-runs, AC2)
# ----------------------------------------------------------------------------
# Creates scratch db kquest_i01_check (drop-if-exists), applies
# CREATE EXTENSION vector, schema.sql, seed.sql, asserts the seed-contract
# minimums from the iteration Specification, then drops the db.
# Exit 0 only on full success. Runs from any cwd (paths resolved relative to
# this script); no absolute paths beyond the psql binary itself.
# Authored plpgsql-free (assert = temp table + CHECK constraint) because the
# local scratch server cannot currently load procedural languages.
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB="kquest_i01_check"

if command -v psql >/dev/null 2>&1; then
  PSQL="psql"
else
  PSQL="/opt/homebrew/bin/psql"
fi

echo "== check-ddl: scratch database $DB =="
rc=0

"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB" || rc=1
if [ $rc -ne 0 ]; then echo "FAIL: could not drop stale scratch db"; exit 1; fi
"$PSQL" -q -d postgres -c "CREATE DATABASE $DB" || { echo "FAIL: could not create scratch db"; exit 1; }
"$PSQL" -q -d "$DB" -c "CREATE EXTENSION vector" \
  || { echo "FAIL: CREATE EXTENSION vector"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }

echo "== applying schema.sql =="
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$SCRIPT_DIR/schema.sql" || rc=1

if [ $rc -eq 0 ]; then
  echo "== applying seed.sql =="
  "$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$SCRIPT_DIR/seed.sql" || rc=1
fi

if [ $rc -eq 0 ]; then
  echo "== asserting seed-contract minimums (Specification, output format) =="
  "$PSQL" -v ON_ERROR_STOP=1 -d "$DB" <<'SQL' || rc=1
CREATE TEMP TABLE ddl_asserts (check_name text PRIMARY KEY, ok boolean NOT NULL);
INSERT INTO ddl_asserts (check_name, ok) VALUES
  ('users >= 2',                         (SELECT count(*) >= 2 FROM users)),
  ('quests >= 2',                        (SELECT count(*) >= 2 FROM quests)),
  ('sources >= 6',                       (SELECT count(*) >= 6 FROM sources)),
  ('agenda sources >= 1',                (SELECT count(*) >= 1 FROM sources WHERE role = 'agenda')),
  ('chunks >= 8',                        (SELECT count(*) >= 8 FROM chunks)),
  ('claims >= 6',                        (SELECT count(*) >= 6 FROM claims)),
  ('terminal definitional-mathematical >= 1', (SELECT count(*) >= 1 FROM claims WHERE terminal_type = 'definitional-mathematical')),
  ('terminal primary-empirical >= 1',          (SELECT count(*) >= 1 FROM claims WHERE terminal_type = 'primary-empirical')),
  ('terminal residual-uncertainty >= 1',       (SELECT count(*) >= 1 FROM claims WHERE terminal_type = 'residual-uncertainty')),
  ('evidence >= 6',                      (SELECT count(*) >= 6 FROM evidence)),
  ('derives_from edges >= 3',            (SELECT count(*) >= 3 FROM claim_derivations)),
  ('frontier entries >= 4',              (SELECT count(*) >= 4 FROM frontier_entries)),
  ('frontier entries open and closed',   (SELECT count(*) >= 1 FROM frontier_entries WHERE state = 'open')
                                        AND (SELECT count(*) >= 1 FROM frontier_entries WHERE state = 'closed')),
  ('frontier needs all distinct',        (SELECT count(*) = count(DISTINCT need) FROM frontier_entries)),
  ('conflicts >= 1',                     (SELECT count(*) >= 1 FROM conflicts)),
  ('a conflict cites >= 2 distinct sources', (SELECT count(*) >= 1 FROM (
      SELECT conflict_id FROM conflict_sources GROUP BY conflict_id HAVING count(*) >= 2) t)),
  ('sessions >= 1',                      (SELECT count(*) >= 1 FROM sessions)),
  ('tool_calls >= 1',                    (SELECT count(*) >= 1 FROM tool_calls)),
  ('usage rows >= 1',                    (SELECT count(*) >= 1 FROM usage_events)),
  ('evidence spans within snapshots',    (SELECT count(*) = 0 FROM evidence WHERE span_end > snapshot_char_count));
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
