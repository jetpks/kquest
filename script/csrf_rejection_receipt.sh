#!/usr/bin/env bash
# ============================================================================
# I20 Part 10 — the CSRF-REJECTION receipt (the graceful rejection's LIVE
# proof; AC11's live-receipt-browser-flow gate). Rides the shared harness
# (bin/live_receipt.sh — the two standing receipts' machinery extracted);
# the CSRF seam is test-env-exempt (hanami-action's env guard), so a live
# development-env server is exactly what this receipt exists to see past.
#
# Run standalone: `bash script/csrf_rejection_receipt.sh` (mounts itself on
# the harness) — or via the harness directly:
#
#   bash bin/live_receipt.sh script/csrf_rejection_receipt.sh csrf_rejection
#
# The door steps (sourced by the harness; BASE/JAR/PSQL/DB/DB_URL/WORK/
# SERVER_LOG/PORT + jar_token() + fail() in scope):
#   (1) RIGHT-token control — POST /workspaces (name=csrf-receipt-01) → the
#       PRG redirect + the workspaces row
#   (2) WRONG token — POST /workspaces (name=csrf-receipt-forged) → 403
#       (never 500/2xx/3xx) + the frozen CSRF_REJECTION_TEXT body + NO row
#   (3) the session SURVIVES the rejection — the SAME jar's right-token POST
#       (name=csrf-receipt-02) → the PRG redirect + the row (the
#       no-session-clear sub-decision's live proof)
#   (4) psql asserts: zero forged rows, two lawful rows
# Final line CSRF_RECEIPT_OK.
# ============================================================================
set -eu

# Not sourced by the harness → mount ourselves on it and exec (the harness
# sources this file back with BASE/jar_token/fail in scope).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  exec bash "$(cd "$(dirname "$0")/.." && pwd)/bin/live_receipt.sh" "$0" csrf_rejection
fi

EXPECTED_REJECTION_BODY="$(cat <<'JSON'
{"error":"CSRF token rejected: the form's security token is missing, stale, or does not match this session — reload the page and resubmit; no changes were made"}
JSON
)"

# ---- (1) RIGHT-token control: the PRG redirect + the workspaces row --------
REDIRECT="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{redirect_url}" \
  -d "name=csrf-receipt-01&_csrf_token=$(jar_token)" "$BASE/workspaces")"
[ "$REDIRECT" = "$BASE/" ] || fail "POST /workspaces (RIGHT token) expected the PRG redirect to /, got '$REDIRECT'"
WS_ONE="$("$PSQL" -q -At -d "$DB" -c "SELECT count(*) FROM workspaces WHERE name = 'csrf-receipt-01'")"
[ "$WS_ONE" = "1" ] || fail "no workspaces row after the right-token control create"
echo "RIGHT_TOKEN_CREATE=302 PRG redirect to $REDIRECT (the row landed)"

# ---- (2) WRONG token: the graceful 403 + the frozen line + NO row -----------
BODY_FILE="$WORK/wrong_token_body.txt"
WRONG_PROBE="$(curl -s -b "$JAR" -c "$JAR" -o "$BODY_FILE" \
  -w "%{http_code} %{content_type}" \
  -d "name=csrf-receipt-forged&_csrf_token=0000forged0000token0000must0000never0000pass000000" \
  "$BASE/workspaces")"
WRONG_STATUS="${WRONG_PROBE%% *}"
WRONG_CONTENT_TYPE="${WRONG_PROBE#* }"
[ "$WRONG_STATUS" = "403" ] || fail "POST /workspaces (WRONG token) expected the graceful 403, got $WRONG_STATUS"
case "$WRONG_CONTENT_TYPE" in
  application/json*) : ;;
  *) fail "the rejection expected the JSON content type, got '$WRONG_CONTENT_TYPE'" ;;
esac
[ "$(cat "$BODY_FILE")" = "$EXPECTED_REJECTION_BODY" ] \
  || fail "the rejection body expected the frozen CSRF_REJECTION_TEXT line, got '$(cat "$BODY_FILE")'"
FORGED="$("$PSQL" -q -At -d "$DB" -c "SELECT count(*) FROM workspaces WHERE name = 'csrf-receipt-forged'")"
[ "$FORGED" = "0" ] || fail "the wrong-token create must land NO row (handle never ran)"
echo "WRONG_TOKEN_CREATE=$WRONG_STATUS 403 + the frozen teaching line (no row — the HALT is load-bearing)"

# ---- (3) the session SURVIVES: the same jar's right-token POST --------------
REDIRECT="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -w "%{redirect_url}" \
  -d "name=csrf-receipt-02&_csrf_token=$(jar_token)" "$BASE/workspaces")"
[ "$REDIRECT" = "$BASE/" ] || fail "POST /workspaces (same jar, right token) expected the PRG redirect, got '$REDIRECT'"
WS_TWO="$("$PSQL" -q -At -d "$DB" -c "SELECT count(*) FROM workspaces WHERE name = 'csrf-receipt-02'")"
[ "$WS_TWO" = "1" ] || fail "no workspaces row after the survival create"
echo "SESSION_SURVIVES=302 PRG redirect to $REDIRECT (the same jar still works — the no-session-clear proof)"

# ---- (4) the psql asserts ----------------------------------------------------
FORGED="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT count(*) FROM workspaces WHERE name = 'csrf-receipt-forged'")"
[ "$FORGED" = "0" ] || fail "expected ZERO forged rows, got '$FORGED'"
LAWFUL="$("$PSQL" -q -At -d "$DB" -c \
  "SELECT count(*) FROM workspaces WHERE name IN ('csrf-receipt-01', 'csrf-receipt-02')")"
[ "$LAWFUL" = "2" ] || fail "expected TWO lawful rows, got '$LAWFUL'"
echo "FORGED_ROWS=$FORGED LAWFUL_ROWS=$LAWFUL"

echo "CSRF_RECEIPT_OK"
