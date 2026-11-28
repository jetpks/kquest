#!/usr/bin/env bash
# ============================================================================
# I19 grant-admin — the BROWSER-FLOW LIVE RECEIPT (frozen AC11; Spec Part 6).
# A clone of script/briefing_chat_receipt.sh (the standing instrument — the
# landed script is NEVER edited). Proves the seven write doors through the
# REAL HTTP surface with CSRF ACTIVE: the test env exempts CSRF (hanami-
# action's env guard) — a live development-env server is exactly what this
# receipt exists to see past.
#
#   scratch DB (the explicit DATABASE_URL env var WINS over dotenv — the
#     fidelity harness's own verified fact) + migrate + seed (no structure
#     dump: `--no-dump` keeps the tree side-effect-free)
#   HANAMI_ENV=development server on a scratch port (CSRF ACTIVE; the
#     developer strategy is mounted only in development — config/app.rb)
#   curl + cookie jar: GET / → XSRF-TOKEN cookie → POST /auth/developer
#     (_csrf_token) → the developer-strategy callback (sign-in; the fixation
#     guard clears + renews the session) → a fresh GET re-issues the new
#     session's XSRF-TOKEN
#   the DOOR SWEEP (Spec Part 6's 13 steps): psql-mint the receipt source
#     (the mint_source CHECK shape) + a second user, then — workspace create
#     with the RIGHT token (PRG + the workspaces AND creator-membership rows
#     asserted), the WRONG token rejected (NOT a 2xx/3xx + no row — the
#     honest current rejection shape; graceful CSRF rejection is ENTRY 3's),
#     a LIVE 422 teach (invalid name, never a 500), member add, rename,
#     public grant (+ v_resource_visibility = public), workspace grant,
#     revoke public (+ the ladder re-derives to workspace), revoke workspace
#     (no grant rows remain — absence = private, the I02 law)
#   teardown on EVERY exit path (trap: kill server, drop DB, rm scratch);
#   final line GRANT_ADMIN_RECEIPT_OK.
#
# Environment note (the I18 PH0-CU-7 class): the dev GET may run ViteRuby's
# autoBuild — the checkout needs node_modules (npm ci) for that path.
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PSQL="${PSQL:-/opt/homebrew/bin/psql}"
DB="i19_grant_receipt"
DB_URL="${I19_RECEIPT_DB_URL:-postgres:///$DB}"
WORK="$(mktemp -d /tmp/kquest_i19_receipt.XXXXXX)"
JAR="$WORK/cookies.txt"
SERVER_LOG="$WORK/server.log"
SERVER_PID=""
PORT=""

cleanup() {
  # The server runs under `bundle exec` inside a subshell: killing $SERVER_PID
  # alone orphans the falcon children — kill the PORT's listeners directly.
  if [ -n "$PORT" ]; then
    pids="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null)"
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
  fi
  [ -n "$SERVER_PID" ] && { pkill -9 -P "$SERVER_PID" 2>/dev/null; kill -9 "$SERVER_PID" 2>/dev/null; }
  sleep 1
  # The DROP needs the server's connections gone — retry past the dying socket.
  for _ in 1 2 3 4 5; do
    "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1 && break
    sleep 1
  done
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

fail() { echo "RECEIPT_FAIL: $*" >&2; exit 1; }

jar_token() { awk '$6=="XSRF-TOKEN" {print $7}' "$JAR" 2>/dev/null; }

# ---- scratch DB: migrate + seed (NO structure dump — side-effect-free) -----
"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB" >/dev/null || fail "drop $DB"
"$PSQL" -q -d postgres -c "CREATE DATABASE $DB" >/dev/null || fail "create $DB"
(cd "$APP_ROOT" && \
  HANAMI_ENV=development DATABASE_URL="$DB_URL" bundle exec hanami db migrate --no-dump --skip-test-db \
) > "$WORK/migrate.log" 2>&1 || { cat "$WORK/migrate.log" >&2; fail "migrate failed"; }
(cd "$APP_ROOT" && \
  HANAMI_ENV=development DATABASE_URL="$DB_URL" bundle exec hanami db seed --skip-test-db \
) > "$WORK/seed.log" 2>&1 || { cat "$WORK/seed.log" >&2; fail "seed failed"; }

# ---- the dev-env server (CSRF ACTIVE) on a scratch port --------------------
PORT=""
for candidate in ${I19_RECEIPT_PORT:-4711} 4713 4717 4719 4723; do
  if ! lsof -iTCP:"$candidate" -sTCP:LISTEN >/dev/null 2>&1; then
    PORT="$candidate"
    break
  fi
done
[ -n "$PORT" ] || fail "no free scratch port"

(cd "$APP_ROOT" && \
  HANAMI_ENV=development DATABASE_URL="$DB_URL" \
  bundle exec hanami server --port "$PORT" > "$SERVER_LOG" 2>&1 \
) &
SERVER_PID=$!
disown $SERVER_PID 2>/dev/null

ready=0
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/up" 2>/dev/null)"
  if [ "$code" = "200" ]; then ready=1; break; fi
  sleep 0.5
done
[ "$ready" = "1" ] || { tail -20 "$SERVER_LOG" >&2; fail "the dev server never came up on :$PORT"; }
echo "== live dev server: http://localhost:$PORT (CSRF ACTIVE) =="

# ---- the browser flow (curl + cookie jar) -----------------------------------
BASE="http://localhost:$PORT"

# 1. Anonymous GET / — mints the session and the XSRF-TOKEN cookie (token A).
code="$(curl -s -c "$JAR" -o /dev/null -w "%{http_code}" "$BASE/")"
[ "$code" = "200" ] || fail "GET / expected 200, got $code"
TOKEN_A="$(jar_token)"
[ -n "$TOKEN_A" ] || fail "GET / issued no XSRF-TOKEN cookie"

# 2. OmniAuth's request phase: the SAME _csrf_token wire, validated (200 form).
code="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{http_code}" \
  -d "_csrf_token=$TOKEN_A" "$BASE/auth/developer")"
[ "$code" = "200" ] || fail "POST /auth/developer (right token) expected 200, got $code"

# 3. The developer-strategy callback signs in. The fixation guard CLEARS +
#    RENEWS the session (sessions/create.rb) — the old token is dead here.
code="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{http_code}" \
  "$BASE/auth/developer/callback?nickname=grant-op&email=grant-op@receipt.test")"
[ "$code" = "302" ] || fail "the developer-strategy callback expected 302, got $code"

# 4. A fresh GET re-issues the NEW session's XSRF-TOKEN (token B) — what a
#    browser picks up after sign-in.
code="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{http_code}" "$BASE/")"
[ "$code" = "200" ] || fail "GET / after sign-in expected 200, got $code"
TOKEN="$(jar_token)"
[ -n "$TOKEN" ] || fail "no XSRF-TOKEN after sign-in"

# ---- psql mints: the receipt SOURCE row (the mint_source CHECK shape; the
#      blob columns are GENERATED, excluded) + the second USER row ----------
OP_ID="$("$PSQL" -q -At -d "$DB" -c "SELECT id FROM users WHERE username = 'grant-op'")"
[ -n "$OP_ID" ] || fail "the signed-in user (grant-op) is missing"
echo "SIGNED_IN_USER=$OP_ID (nickname grant-op)"

URN="kb:src:receiptabc"
SNAP_SHA="$(printf 'the receipt snapshot bytes' | shasum -a 256 | awk '{print $1}')"
RAW_SHA="$(printf 'the receipt raw bytes' | shasum -a 256 | awk '{print $1}')"
"$PSQL" -q -d "$DB" -c \
  "INSERT INTO sources (user_id, url, canonical_url, urn, title, role, fetched_at,
                        snapshot_sha256, raw_sha256, snapshot_char_count)
   VALUES ('$OP_ID', 'https://receipt.test/$URN', 'https://receipt.test/$URN', '$URN',
           'the grant-admin receipt source', 'citable', now(),
           '$SNAP_SHA', '$RAW_SHA', 128)" >/dev/null || fail "the receipt source mint"
SRC_ID="$("$PSQL" -q -At -d "$DB" -c "SELECT id FROM sources WHERE urn = '$URN'")"
[ -n "$SRC_ID" ] || fail "no sources row after the mint"

"$PSQL" -q -d "$DB" -c \
  "INSERT INTO users (handle, github_uid, username, name, email)
   VALUES ('gh-grant-mate-01', 'receipt-mate-uid-0001', 'grant-mate', 'Grant Mate',
           'grant-mate@receipt.test')" >/dev/null || fail "the second user mint"
MATE_ID="$("$PSQL" -q -At -d "$DB" -c "SELECT id FROM users WHERE handle = 'gh-grant-mate-01'")"
[ -n "$MATE_ID" ] || fail "no gh-grant-mate-01 row after the mint"
echo "SOURCE_MINTED=$URN SECOND_USER=gh-grant-mate-01"

# 5. CREATE WORKSPACE with the RIGHT token → the PRG redirect → the
#    workspaces row (created_by = the operator) AND the creator membership.
REDIRECT="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{redirect_url}" \
  -d "name=ws-receipt-01&_csrf_token=$(jar_token)" "$BASE/workspaces")"
[ "$REDIRECT" = "$BASE/" ] || fail "POST /workspaces (RIGHT token) expected the PRG redirect to /, got '$REDIRECT'"
WS_ID="$("$PSQL" -q -At -d "$DB" -c "SELECT id FROM workspaces WHERE name = 'ws-receipt-01'")"
[ -n "$WS_ID" ] || fail "no workspaces row after the right-token create"
WS_OWNER="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT (created_by_user_id = '$OP_ID')::text FROM workspaces WHERE id = '$WS_ID'")"
[ "$WS_OWNER" = "true" ] || fail "the workspaces row's created_by is not the operator"
MEM="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT count(*) FROM workspace_members WHERE workspace_id = '$WS_ID' AND user_id = '$OP_ID'")"
[ "$MEM" = "1" ] || fail "expected the creator membership row, got '$MEM'"
echo "WORKSPACE_CREATED=$WS_ID (created_by + the creator membership row — one transaction)"

# 6. The WRONG token on the SAME door: the CSRF rejection. The honest assert
#    is NOT-A-REDIRECT + no row (the InvalidCSRFTokenError error response;
#    graceful CSRF rejection is ENTRY 3's queued item — not asserted here).
WRONG_STATUS="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{http_code}" \
  -d "name=ws-receipt-forged&_csrf_token=0000forged0000token0000must0000never0000pass000000" \
  "$BASE/workspaces")"
case "$WRONG_STATUS" in
  30*|20*) fail "POST /workspaces (WRONG token) must be REJECTED, got $WRONG_STATUS" ;;
esac
FORGED="$("$PSQL" -q -At -d "$DB" -c "SELECT count(*) FROM workspaces WHERE name = 'ws-receipt-forged'")"
[ "$FORGED" = "0" ] || fail "the wrong-token create must land NO row"
echo "WRONG_TOKEN_CREATE=$WRONG_STATUS (no row — the honest current rejection shape)"

# 7. TEACHING LIVE: an invalid name is a 422 (teach, never a 500), no row.
TEACH_STATUS="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{http_code}" \
  -d "name=NOT-A-SLUG&_csrf_token=$(jar_token)" "$BASE/workspaces")"
[ "$TEACH_STATUS" = "422" ] || fail "POST /workspaces (NOT-A-SLUG) expected the 422 teach, got $TEACH_STATUS"
BAD="$("$PSQL" -q -At -d "$DB" -c "SELECT count(*) FROM workspaces WHERE name = 'NOT-A-SLUG'")"
[ "$BAD" = "0" ] || fail "the 422 teach must land NO row"
echo "TEACHING_422=$TEACH_STATUS (ck_workspaces_name taught — never a CHECK 500)"

# 8. ADD MEMBER (the second user, by handle) → PRG → the membership row.
REDIRECT="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{redirect_url}" \
  -d "handle=gh-grant-mate-01&_csrf_token=$(jar_token)" "$BASE/workspaces/$WS_ID/members")"
[ "$REDIRECT" = "$BASE/" ] || fail "POST members (add) expected the PRG redirect, got '$REDIRECT'"
ADDED="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT count(*) FROM workspace_members WHERE workspace_id = '$WS_ID' AND user_id = '$MATE_ID'")"
[ "$ADDED" = "1" ] || fail "expected the gh-grant-mate-01 membership row, got '$ADDED'"
echo "MEMBER_ADDED=gh-grant-mate-01 (joined_at defaulted — the when-carrier)"

# 9. RENAME → PRG → the row's name.
REDIRECT="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{redirect_url}" \
  -d "name=ws-receipt-01b&_csrf_token=$(jar_token)" "$BASE/workspaces/$WS_ID/rename")"
[ "$REDIRECT" = "$BASE/" ] || fail "POST rename expected the PRG redirect, got '$REDIRECT'"
NAME="$("$PSQL" -q -At -d "$DB" -c "SELECT name FROM workspaces WHERE id = '$WS_ID'")"
[ "$NAME" = "ws-receipt-01b" ] || fail "the rename did not land, name is '$NAME'"
echo "RENAMED=ws-receipt-01b"

# 10. GRANT PUBLIC (source_urn + the REQUIRED note) → PRG → the grant row
#     (owner, is_public, note) AND the real read: the visibility ladder says
#     public.
REDIRECT="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{redirect_url}" \
  -d "source_urn=$URN&note=the receipt public grant&_csrf_token=$(jar_token)" \
  "$BASE/grants/public")"
[ "$REDIRECT" = "$BASE/" ] || fail "POST /grants/public expected the PRG redirect, got '$REDIRECT'"
PUB_ROW="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT (owner_user_id = '$OP_ID')::text || '|' || is_public::text || '|' ||
          (grantee_user_id IS NULL)::text || '|' || (grantee_workspace_id IS NULL)::text || '|' ||
          (note = 'the receipt public grant')::text
   FROM resource_grants WHERE source_id = '$SRC_ID'")"
[ "$PUB_ROW" = "true|true|true|true|true" ] || fail "the public grant row expected 'true|true|true|true|true', got '$PUB_ROW'"
SCOPE="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT effective_scope FROM v_resource_visibility WHERE resource_id = '$SRC_ID'")"
[ "$SCOPE" = "public" ] || fail "the ladder expected effective_scope=public, got '$SCOPE'"
PUB_ID="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT id FROM resource_grants WHERE source_id = '$SRC_ID' AND is_public")"
[ -n "$PUB_ID" ] || fail "no public grant id"
echo "PUBLIC_GRANT=$PUB_ID v_resource_visibility.effective_scope=public (the real read)"

# 11. GRANT WORKSPACE (the workspace door, same source, note) → PRG → row.
REDIRECT="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{redirect_url}" \
  -d "source_urn=$URN&note=the receipt workspace grant&_csrf_token=$(jar_token)" \
  "$BASE/workspaces/$WS_ID/grants")"
[ "$REDIRECT" = "$BASE/" ] || fail "POST workspace grants expected the PRG redirect, got '$REDIRECT'"
WSG_ROW="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT (grantee_workspace_id = '$WS_ID')::text || '|' || is_public::text || '|' ||
          (note = 'the receipt workspace grant')::text
   FROM resource_grants WHERE source_id = '$SRC_ID' AND grantee_workspace_id IS NOT NULL")"
[ "$WSG_ROW" = "true|false|true" ] || fail "the workspace grant row expected 'true|false|true', got '$WSG_ROW'"
COUNT="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT count(*) FROM resource_grants WHERE source_id = '$SRC_ID'")"
[ "$COUNT" = "2" ] || fail "expected TWO grant rows for the source, got '$COUNT'"
WSG_ID="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT id FROM resource_grants WHERE source_id = '$SRC_ID' AND grantee_workspace_id = '$WS_ID'")"
[ -n "$WSG_ID" ] || fail "no workspace grant id"
echo "WORKSPACE_GRANT=$WSG_ID (grantee_workspace_id pinned, is_public=false, note carried)"

# 12. REVOKE the PUBLIC grant → PRG → the public row gone; the workspace
#     grant remains; the ladder re-derives to workspace (the real read).
REDIRECT="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{redirect_url}" \
  -d "_csrf_token=$(jar_token)" "$BASE/grants/$PUB_ID/revoke")"
[ "$REDIRECT" = "$BASE/" ] || fail "POST revoke (public) expected the PRG redirect, got '$REDIRECT'"
GONE="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT count(*) FROM resource_grants WHERE id = '$PUB_ID'")"
[ "$GONE" = "0" ] || fail "the public grant row must be DELETED (revocation IS row deletion)"
COUNT="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT count(*) FROM resource_grants WHERE source_id = '$SRC_ID'")"
[ "$COUNT" = "1" ] || fail "the workspace grant must remain, got '$COUNT' rows"
SCOPE="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT effective_scope FROM v_resource_visibility WHERE resource_id = '$SRC_ID'")"
[ "$SCOPE" = "workspace" ] || fail "the ladder expected effective_scope=workspace, got '$SCOPE'"
echo "PUBLIC_REVOKED v_resource_visibility.effective_scope=workspace (the ladder re-derived)"

# 13. Revoke the workspace grant too → no grant rows remain for the source
#     (absence = private, the I02 law).
REDIRECT="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{redirect_url}" \
  -d "_csrf_token=$(jar_token)" "$BASE/grants/$WSG_ID/revoke")"
[ "$REDIRECT" = "$BASE/" ] || fail "POST revoke (workspace) expected the PRG redirect, got '$REDIRECT'"
COUNT="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT count(*) FROM resource_grants WHERE source_id = '$SRC_ID'")"
[ "$COUNT" = "0" ] || fail "expected NO grant rows for the source (private = absence), got '$COUNT'"
echo "WORKSPACE_REVOKED — no grant rows remain for $URN (private = absence, the I02 law)"

echo "GRANT_ADMIN_RECEIPT_OK"
