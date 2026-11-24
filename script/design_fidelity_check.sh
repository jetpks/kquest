#!/usr/bin/env bash
# ============================================================================
# I11 migration fidelity harness (frozen Specification Part 4, gate
# `migration-fidelity`, AC1).
# ----------------------------------------------------------------------------
# Proves the app's OWN migrations produce a schema whose LAW-BEARING catalog
# is identical to the design DDL applied verbatim:
#   side A  = scratch db from the design files via psql (I01 schema.sql +
#             I02 schema-i02.sql + I03 schema-i03.sql — NO seeds)
#   side B  = scratch db from the app's migrations
#             (HANAMI_ENV=test DATABASE_URL=... bundle exec hanami db migrate)
# Both sides digest with the SAME canonical catalog query
# (script/design_fidelity_catalog.sql); the sha256s MUST match.
#
# Fidelity law notes:
#   - The db names MUST end in `_test` (hanami appends the suffix in test env).
#   - The explicit DATABASE_URL env var WINS over dotenv (.env.test) — verified.
#   - `db migrate` on side B re-dumps config/db/structure.sql; because the
#     migrated schema is law-identical to the design schema, the re-dump is
#     byte-identical to the committed structure file (the migrations-cold
#     gate pins that separately via the prepare re-dump law).
#   - structure.sql is deliberately NOT a digest side: pg_dump's round-trip
#     re-serializes some CHECK constraints (row-IN flattening), so deparse
#     equality is over-strict for it.
#
# psql hygiene: drop-if-exists scratch dbs on EVERY exit path (trap), outputs
# to files, never pipe psql through head.
#
# Exit 0 + FIDELITY_OK on match; exit 1 + FIDELITY_FAIL + a diff on stderr
# on mismatch.
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PSQL="${PSQL:-psql}"
CATALOG="$SCRIPT_DIR/design_fidelity_catalog.sql"

DB_A="i11_fidelity_design_test"
DB_B="i11_fidelity_migrate_test"
WORK="$(mktemp -d /tmp/kquest_i11_fid.XXXXXX)"

cleanup() {
  "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB_B" >/dev/null 2>&1
  "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB_A" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FIDELITY_FAIL: $1" >&2; exit 1; }

[ -f "$CATALOG" ] || fail "missing catalog query: $CATALOG"

# CI portability (I12 Part 5): the sha256 tool resolves loudly — `sha256sum`
# (ubuntu) or `shasum -a 256` (macOS); no fallback, no silent drift.
if command -v sha256sum >/dev/null 2>&1; then
  SHA256_TOOL="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA256_TOOL="shasum -a 256"
else
  fail "no sha256 tool found (need sha256sum or shasum)"
fi

# ---- side A: design DDL applied verbatim (psql, no seeds) -------------------
"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB_A" >/dev/null || fail "drop $DB_A"
"$PSQL" -q -d postgres -c "CREATE DATABASE $DB_A" >/dev/null || fail "create $DB_A"
for f in \
  "$APP_ROOT/design/I01-core-model/artifacts/schema.sql" \
  "$APP_ROOT/design/I02-cross-quest/artifacts/schema-i02.sql" \
  "$APP_ROOT/design/I03-retrieval/artifacts/schema-i03.sql"; do
  "$PSQL" -q -v ON_ERROR_STOP=1 -d "$DB_A" -f "$f" > "$WORK/side_a_apply.log" 2>&1 \
    || { cat "$WORK/side_a_apply.log" >&2; fail "design DDL failed: $f"; }
done

# ---- side B: the app's own migrations ---------------------------------------
# --no-dump: side B's db is built by MIGRATIONS, so a default dump would
# re-serialize config/db/structure.sql from a migrate-built catalog (the
# row-IN CHECKs deparse nested-OR there) and clobber the committed file —
# whose law is the PREPARE fixed point (prepare loads + re-dumps it
# byte-identically; the migrations-cold gate pins that). The harness must be
# side-effect-free on the tree.
"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB_B" >/dev/null || fail "drop $DB_B"
"$PSQL" -q -d postgres -c "CREATE DATABASE $DB_B" >/dev/null || fail "create $DB_B"
(cd "$APP_ROOT" && \
  HANAMI_ENV=test DATABASE_URL="${DB_URL_BASE:-postgres:///}$DB_B" bundle exec hanami db migrate --no-dump \
) > "$WORK/side_b_migrate.log" 2>&1 \
  || { cat "$WORK/side_b_migrate.log" >&2; fail "app migrations failed (side B)"; }

# ---- digest both sides with the ONE canonical catalog query -----------------
"$PSQL" -q -At -d "$DB_A" -f "$CATALOG" > "$WORK/side_a.txt" 2> "$WORK/side_a.err" \
  || { cat "$WORK/side_a.err" >&2; fail "catalog query failed on side A"; }
"$PSQL" -q -At -d "$DB_B" -f "$CATALOG" > "$WORK/side_b.txt" 2> "$WORK/side_b.err" \
  || { cat "$WORK/side_b.err" >&2; fail "catalog query failed on side B"; }

SHA_A="$($SHA256_TOOL "$WORK/side_a.txt" | cut -d' ' -f1)"
SHA_B="$($SHA256_TOOL "$WORK/side_b.txt" | cut -d' ' -f1)"
N_A="$(wc -l < "$WORK/side_a.txt" | tr -d ' ')"
N_B="$(wc -l < "$WORK/side_b.txt" | tr -d ' ')"

echo "design side:  $N_A law objects, sha256 $SHA_A"
echo "migrate side: $N_B law objects, sha256 $SHA_B"

if [ "$SHA_A" != "$SHA_B" ]; then
  diff "$WORK/side_a.txt" "$WORK/side_b.txt" > "$WORK/law.diff" 2>&1 || true
  cat "$WORK/law.diff" >&2
  fail "digest mismatch"
fi

echo "FIDELITY_OK"
