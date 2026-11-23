#!/usr/bin/env bash
# ============================================================================
# kquest I07 assurance — check-coverage.sh (gate: coverage-checks,
# AC1/AC3/AC4/AC6/AC7)
# ----------------------------------------------------------------------------
# Validates, against the files in this directory (paths relative to script):
#   1. Traceability (AC1): DESIGN.md's traceability table covers R-066..R-072
#      exactly once each, status DESIGNED or DEFERRED; a DEFERRED row names a
#      destination (ENTRY 8 or the implementation arc).
#   2. DECISIONS.md structure (AC6): DR-01.. sequential and unique; every
#      record has non-empty Status/Decision/Rationale/Alternatives;
#      OPERATOR-RULING-NEEDED records carry Options + Recommendation; the six
#      REQUIRED records present (audit cadence, spot-check sampling,
#      conflict-ledger shape, stall thresholds, blind-spot scope, ladder
#      gate criteria).
#   3. Predicate-catalog parity (AC3, both directions): every tw_* view in
#      tripwires-i07.sql appears in DESIGN.md's catalog and every tw_*
#      named in DESIGN.md exists as a view in the SQL. No prose-only
#      tripwires (R-069).
#   4. Threshold parity vs I06 (AC4): the shared values (SR-08=3,
#      SR-15=450000, SR-16=496000, SR-17=100, SR-18=1200, SR-19=3600)
#      match stop-rules.tsv defaults exactly AND appear in tripwires-i07.sql
#      and DESIGN.md; a mismatch is legal ONLY with a DECISIONS record
#      amending the SR row explicitly (none expected — DR-04 records the
#      no-amendment posture).
#   5. Prior-law immutability (AC7): design/I01..I06 — all SIX dirs —
#      byte-identical to the ratified (committed) state (git diff empty,
#      no untracked additions, all tracked files present).
# Exit 0 only on full success. macOS bash 3.2 safe.
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESIGN="$SCRIPT_DIR/../DESIGN.md"
DECISIONS="$SCRIPT_DIR/../DECISIONS.md"
SQL="$SCRIPT_DIR/tripwires-i07.sql"
STOP="$SCRIPT_DIR/../../I06-quest-process/artifacts/stop-rules.tsv"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="$(mktemp -d /tmp/kquest_i07_cov.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
fail() { echo "FAIL  $1"; FAILED=$((FAILED+1)); }
pass() { echo "pass  $1"; }

for f in "$DESIGN" "$DECISIONS" "$SQL" "$STOP"; do
  [ -f "$f" ] || { echo "FAIL  missing $f"; exit 1; }
done

echo "== 1. traceability: R-066..R-072 in DESIGN.md =="
i=66
while [ $i -le 72 ]; do
  rid=$(printf 'R-%03d' $i)
  n=$(grep -c "^| $rid |" "$DESIGN" 2>/dev/null)
  n=${n:-0}
  if [ "$n" -ne 1 ]; then
    fail "$rid appears $n times in the traceability table (expected exactly 1)"
    i=$((i+1)); continue
  fi
  row=$(grep "^| $rid |" "$DESIGN")
  status=$(echo "$row" | awk -F'|' '{ gsub(/ /, "", $3); print $3 }')
  case "$status" in
    DESIGNED) pass "$rid DESIGNED" ;;
    DEFERRED)
      if echo "$row" | grep -qE 'ENTRY 8|implementation arc'; then
        pass "$rid DEFERRED -> $(echo "$row" | grep -oE 'ENTRY 8|implementation arc' | head -1)"
      else
        fail "$rid DEFERRED but names no destination (ENTRY 8 / implementation arc)"
      fi ;;
    *) fail "$rid has unrecognized status '$status' (want DESIGNED or DEFERRED)" ;;
  esac
  i=$((i+1))
done

echo "== 2. DECISIONS.md structure (AC6) =="
grep '^## DR-' "$DECISIONS" > "$WORK/headers" || true
nrec=$(wc -l < "$WORK/headers" | tr -d ' ')
if [ "$nrec" -eq 0 ]; then
  fail "no '## DR-' records found in DECISIONS.md"
else
  sed 's/^## DR-//; s/ .*//' "$WORK/headers" > "$WORK/nums"
  uniq_dupes=$(sort "$WORK/nums" | uniq -d | tr -d '\n' | sed 's/ /,/g')
  seq -w 1 "$nrec" > "$WORK/want"
  if cmp -s "$WORK/want" "$WORK/nums" && [ -z "$uniq_dupes" ]; then
    pass "DR numbering sequential DR-01..DR-$(printf '%02d' "$nrec"), all unique"
  else
    fail "DR numbering not sequential from 01 or not unique (dupes: '$uniq_dupes'): got $(tr '\n' ' ' < "$WORK/nums")"
  fi

  awk -v d="$WORK" '
    /^## DR-/ { n++; close(f); f = sprintf("%s/blk_%02d", d, n); next }
    /^## /   { close(f); f = ""; next }
    f != "" { print > f }
  ' "$DECISIONS"

  k=1
  while [ $k -le "$nrec" ]; do
    dr=$(printf 'DR-%02d' $k)
    blk="$WORK/blk_$(printf '%02d' $k)"
    ok=1
    for field in "Decision" "Rationale" "Alternatives considered"; do
      marker_line=$(grep -n "\*\*${field}" "$blk" | head -1 | cut -d: -f1)
      if [ -z "$marker_line" ]; then
        fail "$dr missing a '**${field}**' field"
        ok=0; continue
      fi
      rest=$(sed -n "${marker_line}p" "$blk" | sed "s/.*\*\*${field}[^*]*\*\*//")
      if [ -z "$(echo "$rest" | tr -d '[:space:]')" ]; then
        nxt=$(sed -n "$((marker_line+1))p" "$blk")
        if [ -z "$nxt" ] || echo "$nxt" | grep -q '^\*\*[A-Z]'; then
          fail "$dr field '$field' is empty"
          ok=0
        fi
      fi
    done
    [ $ok -eq 1 ] && pass "$dr has non-empty Decision/Rationale/Alternatives"

    status_line=$(grep -m1 '\*\*Status:\*\*' "$blk" | sed 's/.*\*\*Status:\*\* *//')
    case "$status_line" in
      DECIDED*) ;;
      OPERATOR-RULING-NEEDED*)
        if grep -q '\*\*Options:\*\*' "$blk" && grep -q '\*\*Recommendation:\*\*' "$blk"; then
          pass "$dr OPERATOR-RULING-NEEDED with Options + Recommendation"
        else
          fail "$dr flagged OPERATOR-RULING-NEEDED but lacks Options/Recommendation"
        fi ;;
      "") fail "$dr has no '**Status:**' line" ;;
      *) fail "$dr has unrecognized Status '$status_line' (want DECIDED or OPERATOR-RULING-NEEDED)" ;;
    esac
    k=$((k+1))
  done

  echo "== 2b. the six REQUIRED decision records =="
  for token in "audit cadence" "Spot-check sampling" "Conflict-ledger shape" \
               "Stall-signal thresholds" "Blind-spot scope" "Ladder gate criteria"; do
    if grep -i -q -- "$token" "$WORK/headers"; then
      pass "required record present (header token '$token')"
    else
      fail "required record MISSING (no DR header matching '$token')"
    fi
  done
fi
echo "info  OPERATOR-RULING-NEEDED records: $(grep -c '\*\*Status:\*\* OPERATOR-RULING-NEEDED' "$DECISIONS")"

echo "== 3. predicate-catalog parity, both directions (AC3: no prose-only tripwires) =="
grep -oE 'CREATE OR REPLACE VIEW tw_[a-z_]+' "$SQL" | awk '{print $NF}' | sort -u > "$WORK/tw_sql"
nsql=$(wc -l < "$WORK/tw_sql" | tr -d ' ')
pass "SQL defines $nsql tw_* views: $(tr '\n' ' ' < "$WORK/tw_sql")"
grep -oE 'tw_[a-z_]+' "$DESIGN" | sort -u > "$WORK/tw_design"
# DESIGN mentions only catalog predicates; compare
ONLY_SQL=$(comm -23 "$WORK/tw_sql" "$WORK/tw_design" | tr '\n' ' ')
ONLY_DESIGN=$(comm -13 "$WORK/tw_sql" "$WORK/tw_design" | tr '\n' ' ')
[ -n "$ONLY_SQL" ] && fail "views in SQL never named in DESIGN catalog (prose-only catalog hole): $ONLY_SQL"
[ -n "$ONLY_DESIGN" ] && fail "tripwires named in DESIGN with no executable view (PROSE-ONLY TRIPWIRE): $ONLY_DESIGN"
if [ -z "$ONLY_SQL" ] && [ -z "$ONLY_DESIGN" ]; then
  pass "predicate <-> catalog parity 1:1 both directions ($nsql predicates)"
fi

echo "== 4. threshold parity vs I06 stop-rules.tsv (AC4) =="
# pairs: rule_id -> the value that must match stop-rules' default AND appear
# in both tripwires-i07.sql and DESIGN.md. A pair may mismatch ONLY if a
# DECISIONS record explicitly amends that SR row (grep 'AMEND SR-xx').
check_pair() { # $1 rule id, $2 value
  local rule="$1" val="$2" defrow defval
  defrow=$(awk -F'\t' -v r="$rule" '$1 == r' "$STOP")
  if [ -z "$defrow" ]; then
    fail "$rule not found in stop-rules.tsv"; return
  fi
  defval=$(echo "$defrow" | awk -F'\t' '{print $4}')
  if [ "$defval" != "$val" ]; then
    if grep -q "AMEND $rule" "$DECISIONS"; then
      pass "$rule default $defval != catalog $val, but a DECISIONS record amends it"
    else
      fail "$rule default is $defval in stop-rules.tsv but $val in the I07 pair set (no amending DR)"
    fi
    return
  fi
  if grep -qE "${rule}[^0-9]*${val}([^0-9]|$)" "$SQL" \
     && grep -qE "${rule}[^0-9]*${val}([^0-9]|$)" "$DESIGN"; then
    pass "$rule = $val matches stop-rules and appears in SQL + DESIGN"
  else
    fail "$rule = $val matches stop-rules but the pair is not stated in BOTH tripwires-i07.sql and DESIGN.md"
  fi
}
check_pair SR-08 3
check_pair SR-15 450000
check_pair SR-16 496000
check_pair SR-17 100
check_pair SR-18 1200
check_pair SR-19 3600
# DR-04 must record the no-amendment posture
if grep -q "DR-04" "$DECISIONS" && grep -A6 "## DR-04" "$DECISIONS" | grep -qi "no amendment\|amend nothing\|amends nothing"; then
  pass "DR-04 records the match-I06-amend-nothing posture"
else
  fail "DR-04 does not record the stall-threshold no-amendment posture"
fi

echo "== 5. prior-law immutability (AC7: I01..I06 all SIX byte-identical) =="
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  fail "worktree is not a git repository — cannot verify prior-law immutability"
else
  head_sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)
  echo "info  worktree HEAD: $head_sha"
  ok_all=1
  for dir in design/I01-core-model design/I02-cross-quest design/I03-retrieval design/I04-agent-loop design/I05-tool-surface design/I06-quest-process; do
    drift=""
    git -C "$ROOT" diff --quiet HEAD -- "$dir" || drift="diff"
    [ -n "$(git -C "$ROOT" status --porcelain -- "$dir")" ] && drift="$drift status"
    missing=""
    for tf in $(git -C "$ROOT" ls-files -- "$dir"); do
      [ -f "$ROOT/$tf" ] || missing="$missing $tf"
    done
    if [ -n "$drift" ] || [ -n "$missing" ]; then
      fail "$dir/ DRIFTED from ratified state ($drift$missing):"
      git -C "$ROOT" status --porcelain -- "$dir" | sed 's/^/      /'
      git -C "$ROOT" diff --stat HEAD -- "$dir" | sed 's/^/      /'
      ok_all=0
    else
      nfiles=$(git -C "$ROOT" ls-files -- "$dir" | wc -l | tr -d ' ')
      pass "$dir/ byte-identical to ratified state ($nfiles tracked files, diff empty, no untracked)"
    fi
  done
fi

if [ "$FAILED" -eq 0 ]; then
  echo "check-coverage: PASS"
  exit 0
else
  echo "check-coverage: FAIL ($FAILED problems)"
  exit 1
fi
