#!/usr/bin/env bash
# ============================================================================
# I18 briefing chat — the BROWSER-FLOW LIVE RECEIPT (frozen AC14; Spec Part
# 2.7). Proves the enqueue door through the REAL HTTP surface with CSRF
# ACTIVE: the test env exempts CSRF (hanami-action's env guard) — a live
# development-env server is exactly what this receipt exists to see past.
#
#   scratch DB (the explicit DATABASE_URL env var WINS over dotenv — the
#     fidelity harness's own verified fact) + migrate + seed (no structure
#     dump: `--no-dump` keeps the tree side-effect-free)
#   HANAMI_ENV=development server on a scratch port (CSRF ACTIVE; the
#     developer strategy is mounted only in development — config/app.rb)
#   curl + cookie jar: GET / → XSRF-TOKEN cookie → POST /auth/developer
#     (OmniAuth's request phase validates the SAME _csrf_token wire) → the
#     developer-strategy callback (sign-in; the fixation guard clears +
#     renews the session — app/actions/sessions/create.rb) → a fresh GET
#     re-issues the new session's XSRF-TOKEN → quest create → session open →
#     operator turn submit with the RIGHT token (the PRG redirect) AND with
#     a WRONG token (the CSRF rejection — BOTH sides, the lesson's law)
#   psql asserts: the briefing_turns row (state enqueued), the OPEN operator
#     sessions row, ZERO tool_calls / usage_events rows for the quest (no
#     LLM/web call ran in the web process — BRIEF §3 zero-auto)
#   teardown on EVERY exit path (trap: kill server, drop DB, rm scratch);
#   final line BROWSER_RECEIPT_OK.
#
# Environment note (the lane's PH0-CU-7): the dev GET may run ViteRuby's
# autoBuild — the checkout needs node_modules (npm ci) for that path.
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PSQL="${PSQL:-/opt/homebrew/bin/psql}"
DB="i18_chat_receipt"
DB_URL="${I18_RECEIPT_DB_URL:-postgres:///$DB}"
WORK="$(mktemp -d /tmp/kquest_i18_receipt.XXXXXX)"
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
for candidate in ${I18_RECEIPT_PORT:-4691} 4693 4697 4701 4703; do
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
  "$BASE/auth/developer/callback?nickname=receipt-op&email=receipt-op@receipt.test")"
[ "$code" = "302" ] || fail "the developer-strategy callback expected 302, got $code"

# 4. A fresh GET re-issues the NEW session's XSRF-TOKEN (token B) — what a
#    browser picks up after sign-in.
code="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{http_code}" "$BASE/")"
[ "$code" = "200" ] || fail "GET / after sign-in expected 200, got $code"
TOKEN="$(jar_token)"
[ -n "$TOKEN" ] || fail "no XSRF-TOKEN after sign-in"

# 5. Quest create → the row only (I16 Part 3).
REDIRECT="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{redirect_url}" \
  -d "topic=the receipt probe quest&web_call_budget=16&token_budget=1000000&spend_budget_usd=1.0&_csrf_token=$(jar_token)" \
  "$BASE/quests")"
case "$REDIRECT" in
  "$BASE/quests/"*) QUEST_ID="${REDIRECT##*/}" ;;
  *) fail "POST /quests expected the PRG redirect to /quests/<id>, got '$REDIRECT'" ;;
esac
echo "== quest created: $QUEST_ID =="

# 6. Session open (the seizure; mode interactive, driver operator).
REDIRECT="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{redirect_url}" \
  -d "_csrf_token=$(jar_token)" "$BASE/quests/$QUEST_ID/briefing/session")"
[ "$REDIRECT" = "$BASE/quests/$QUEST_ID/briefing" ] \
  || fail "POST briefing/session expected the PRG redirect to the briefing, got '$REDIRECT'"

# 7. THE RIGHT TOKEN: the operator turn submit — expect the PRG redirect.
REDIRECT="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{redirect_url}" \
  -d "body=what is the scope of the decay question?&_csrf_token=$(jar_token)" \
  "$BASE/quests/$QUEST_ID/briefing/turns")"
[ "$REDIRECT" = "$BASE/quests/$QUEST_ID/briefing" ] \
  || fail "POST briefing/turns (RIGHT token) expected the PRG redirect, got '$REDIRECT'"
echo "RIGHT_TOKEN_SUBMIT=302 PRG redirect to $REDIRECT"

# 8. THE WRONG TOKEN: the forged submit — the CSRF rejection. PH0-CU-5: no
#    custom handler exists, so the rejection is the InvalidCSRFTokenError
#    error response (500-class) — the honest assert is NOT-A-REDIRECT + no
#    row. (Test env exempts CSRF; this live server is what sees past that.)
WRONG_STATUS="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{http_code}" \
  -d "body=the forged turn&_csrf_token=0000forged0000token0000must0000never0000pass000000" \
  "$BASE/quests/$QUEST_ID/briefing/turns")"
case "$WRONG_STATUS" in
  30*|20*) fail "POST briefing/turns (WRONG token) must be REJECTED, got $WRONG_STATUS" ;;
esac
echo "WRONG_TOKEN_SUBMIT=$WRONG_STATUS (the CSRF rejection — no redirect, no row)"

# ---- the PG asserts (the receipt's receipts) --------------------------------
ROW="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT state || '|' || seq || '|' || body FROM briefing_turns WHERE quest_id = '$QUEST_ID'")"
[ "$ROW" = "enqueued|1|what is the scope of the decay question?" ] \
  || fail "the briefing_turns row expected 'enqueued|1|<body>', got '$ROW'"
echo "BRIEFING_TURNS_ROW=$ROW (state enqueued)"

SESSION="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT count(*) FROM sessions WHERE quest_id = '$QUEST_ID' AND driver = 'operator' \
   AND ended_at IS NULL")"
[ "$SESSION" = "1" ] || fail "expected exactly ONE open operator session row, got '$SESSION'"
echo "SESSIONS_ROW=open operator session (driver operator, ended_at IS NULL)"

ZERO="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT (SELECT count(*) FROM tool_calls WHERE quest_id = '$QUEST_ID') || '/' || \
          (SELECT count(*) FROM usage_events WHERE quest_id = '$QUEST_ID')")"
[ "$ZERO" = "0/0" ] || fail "expected ZERO tool_calls/usage_events rows for the quest, got '$ZERO'"
echo "TOOL_CALLS=0 USAGE_EVENTS=0 (no LLM/web call ran in the web process — zero-auto)"

echo "BROWSER_RECEIPT_OK"
