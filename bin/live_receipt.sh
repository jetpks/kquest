#!/usr/bin/env bash
# ============================================================================
# The LIVE-RECEIPT HARNESS (I20 Part 10 — the plan's Plus item, judged cheap):
# the two standing receipts' (script/briefing_chat_receipt.sh +
# script/grant_admin_receipt.sh — byte-unchanged shields) shared machinery,
# extracted into ONE parameterized runner.
#
#   bin/live_receipt.sh <steps-file> [name]
#
#   scratch DB `receipt_<name>` (drop/create; the explicit DATABASE_URL env
#     var WINS over dotenv — the fidelity harness's own verified fact) +
#     migrate + seed (no structure dump: `--no-dump` keeps the tree
#     side-effect-free)
#   HANAMI_ENV=development server on a scratch port (CSRF ACTIVE; the
#     developer strategy is mounted only in development — config/app.rb)
#   cookie-jar sign-in dance: anonymous GET → XSRF-TOKEN → POST
#     /auth/developer with `_csrf_token` → the developer-strategy callback
#     (sign-in; the fixation guard clears + renews the session) → a fresh GET
#     re-issues the new session's XSRF-TOKEN
#   teardown on EVERY exit path (trap: kill the port's listeners + the
#     server's children, DROP DATABASE with the dying-socket retry, rm the
#     scratch dir)
#
# EXPORTS to the sourced steps file: BASE, JAR, PSQL, DB, DB_URL, WORK,
# SERVER_LOG, PORT, jar_token(), fail(). The steps file asserts
# door-by-door and ends with its own final marker line.
#
# Environment note (the I18 PH0-CU-7 class): the dev GET may run ViteRuby's
# autoBuild — the checkout needs node_modules (npm ci) for that path.
# ============================================================================
set -u

STEPS_FILE="${1:?usage: bin/live_receipt.sh <steps-file> [name]}"
NAME="${2:-receipt}"
[ -f "$STEPS_FILE" ] || { echo "RECEIPT_FAIL: no such steps file: $STEPS_FILE" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PSQL="${PSQL:-/opt/homebrew/bin/psql}"
DB="receipt_$NAME"
DB_URL="${RECEIPT_DB_URL:-postgres:///$DB}"
WORK="$(mktemp -d /tmp/kquest_${NAME}_receipt.XXXXXX)"
JAR="$WORK/cookies.txt"
SERVER_LOG="$WORK/server.log"
SERVER_PID=""
PORT=""

cleanup() {
  # Errexit-safety (judge F-1, landed driver-seat per PASS-WITH-FIXES): the
  # sourced receipt script runs `set -eu` in THIS shell — its EXIT trap must
  # stay best-effort or a no-match pkill/kill leg aborts cleanup mid-flight
  # (exit 1 + scratch DB left behind, deterministically, on the race).
  set +e
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
for candidate in ${RECEIPT_PORT:-4731} 4733 4737 4739 4741; do
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

# ---- the cookie-jar sign-in dance -------------------------------------------
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
  "$BASE/auth/developer/callback?nickname=${NAME}-receipt-op&email=${NAME}-receipt-op@receipt.test")"
[ "$code" = "302" ] || fail "the developer-strategy callback expected 302, got $code"

# 4. A fresh GET re-issues the NEW session's XSRF-TOKEN (token B) — what a
#    browser picks up after sign-in.
code="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{http_code}" "$BASE/")"
[ "$code" = "200" ] || fail "GET / after sign-in expected 200, got $code"
[ -n "$(jar_token)" ] || fail "no XSRF-TOKEN after sign-in"

# ---- the door steps (the sourced file carries the receipt's own assertions
#      and its final marker line) ----------------------------------------------
# shellcheck disable=SC1090
source "$STEPS_FILE"
