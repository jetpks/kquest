#!/usr/bin/env bash
# ============================================================================
# kquest I05 tool-surface — check-coverage.sh (gate: coverage-checks,
# AC1/AC4/AC6/AC7/AC8)
# ----------------------------------------------------------------------------
# Validates, against the files in this directory (paths relative to script):
#   1. Traceability (AC1): DESIGN.md's traceability table covers R-047..R-055
#      exactly once each, status DESIGNED or DEFERRED; a DEFERRED row names a
#      destination (ENTRY 6/7/8 or the implementation arc).
#   2. DECISIONS.md structure (AC7): DR-01.. sequential and unique; every
#      record has non-empty Status / Decision / Rationale / Alternatives
#      considered; OPERATOR-RULING-NEEDED records carry Options +
#      Recommendation; the six REQUIRED records are present (refusal dialect,
#      coercion write-back boundary, container-naming law, sliced-read
#      defaults, unknown-tool response, profile restriction mechanics).
#   3. Status=gate parity (AC6): the DESIGN parity block is 1:1 BOTH
#      directions with the frozen canonical result lines in the status and
#      quest_status fixtures — every parity row names a field the agent sees,
#      every field the agent sees has a parity row (gate rule or named
#      consuming rule); no decorative fields.
#   4. Prior-law immutability (AC8): design/I01-core-model/, design/I02-
#      cross-quest/, design/I03-retrieval/ AND design/I04-agent-loop/ are
#      byte-identical to their ratified (committed) state — git diff empty vs
#      worktree HEAD AND no untracked additions under any of the four — and
#      all ratified files are present.
# Exit 0 only on full success. macOS bash 3.2 safe.
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESIGN="$SCRIPT_DIR/../DESIGN.md"
DECISIONS="$SCRIPT_DIR/../DECISIONS.md"
FIX_STATUS="$SCRIPT_DIR/fixtures/status.md"
FIX_QSTATUS="$SCRIPT_DIR/fixtures/quest_status.md"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
I01DIR="$ROOT/design/I01-core-model"
I02DIR="$ROOT/design/I02-cross-quest"
I03DIR="$ROOT/design/I03-retrieval"
I04DIR="$ROOT/design/I04-agent-loop"
WORK="$(mktemp -d /tmp/kquest_i05_cov.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
fail() { echo "FAIL  $1"; FAILED=$((FAILED+1)); }
pass() { echo "pass  $1"; }

for f in "$DESIGN" "$DECISIONS" "$FIX_STATUS" "$FIX_QSTATUS"; do
  [ -f "$f" ] || { echo "FAIL  missing $f"; exit 1; }
done

echo "== 1. traceability: R-047..R-055 in DESIGN.md =="
i=47
while [ $i -le 55 ]; do
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
    DESIGNED)
      pass "$rid DESIGNED"
      ;;
    DEFERRED)
      if echo "$row" | grep -qE 'ENTRY [6-8]|implementation arc'; then
        pass "$rid DEFERRED -> $(echo "$row" | grep -oE 'ENTRY [6-8]|implementation arc' | head -1)"
      else
        fail "$rid DEFERRED but names no destination ENTRY 6..8 / implementation arc"
      fi
      ;;
    *)
      fail "$rid has unrecognized status '$status' (want DESIGNED or DEFERRED)"
      ;;
  esac
  i=$((i+1))
done

echo "== 2. DECISIONS.md structure (AC7) =="
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
    /^## /    { close(f); f = ""; next }
    f != ""  { print > f }
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
        ok=0
        continue
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
        fi
        ;;
      "")
        fail "$dr has no '**Status:**' line"
        ;;
      *)
        fail "$dr has unrecognized Status '$status_line' (want DECIDED or OPERATOR-RULING-NEEDED)"
        ;;
    esac
    k=$((k+1))
  done

  echo "== 2b. the six REQUIRED decision records =="
  for topic in "refusal dialect:refusal dialect" "coercion write-back:coercion write-back" \
               "container-naming law:container-naming" "sliced-read defaults:sliced-read defaults" \
               "unknown-tool response:unknown-tool response" "profile restriction mechanics:profile restriction mechanics"; do
    name="${topic%%:*}"; token="${topic#*:}"
    if grep -i -q -- "$token" "$WORK/headers"; then
      pass "required record present: $name (header token '$token')"
    else
      fail "required record MISSING: $name (no DR header matching '$token')"
    fi
  done
fi
echo "info  OPERATOR-RULING-NEEDED records: $(grep -c '\*\*Status:\*\* OPERATOR-RULING-NEEDED' "$DECISIONS")"

echo "== 3. status=gate parity, 1:1 both directions (AC6) =="
# Parity block rows: "<gate|rule>: <name> (<…>) | <tool>.<field>"
awk '/^```parity[[:space:]]*$/ { inm=1; next }
     inm && /^```$/ { inm=0; next }
     inm && NF > 0 { print }' "$DESIGN" > "$WORK/parity"
npar=$(wc -l < "$WORK/parity" | tr -d ' ')
if [ "$npar" -eq 0 ]; then
  fail "DESIGN.md has no fenced 'parity' block (or it is empty)"
else
  pass "parity block: $npar rows"
fi
badkind=$(grep -vcE '^(gate|rule): ' "$WORK/parity")
[ "$badkind" -gt 0 ] && fail "$badkind parity rows do not start with 'gate:' or 'rule:'"
sed 's/^.*| //' "$WORK/parity" | sed 's/[[:space:]]//g' | sort > "$WORK/parity_fields_raw"
npf=$(wc -l < "$WORK/parity_fields_raw" | tr -d ' ')
dupf=$(uniq -d < "$WORK/parity_fields_raw" | tr '\n' ' ')
[ -n "$dupf" ] && fail "duplicate parity field rows: $dupf"

# Fixture side: frozen canonical result lines.
extract_fields() { # $1 = fixture, $2 = result-line prefix
  grep -m1 "^$2: " "$1" | grep -o '[a-z_]*=' | sed 's/=$//' | sort -u
}
extract_fields "$FIX_STATUS" "status" > "$WORK/status_fields"
extract_fields "$FIX_QSTATUS" "quest_status" > "$WORK/qstatus_fields"

# tool-scoped comparison, both directions
for pair in "status:$WORK/status_fields" "quest_status:$WORK/qstatus_fields"; do
  tool="${pair%%:*}"; fset="${pair#*:}"
  grep "^${tool}\\." "$WORK/parity_fields_raw" | sed "s/^${tool}\\.//" > "$WORK/want_fields"
  only_parity=$(comm -23 "$WORK/want_fields" "$fset" | tr '\n' ' ')
  only_fixture=$(comm -13 "$WORK/want_fields" "$fset" | tr '\n' ' ')
  if [ -n "$only_parity" ]; then
    fail "$tool: parity rows without a status field the agent sees: $only_parity"
  fi
  if [ -n "$only_fixture" ]; then
    fail "$tool: status fields with no parity row (decorative?): $only_fixture"
  fi
  [ -z "$only_parity" ] && [ -z "$only_fixture" ] && \
    pass "$tool: parity 1:1 both directions ($(wc -l < "$fset" | tr -d ' ') fields)"
done
# cross-tool leakage: parity rows must only name the two status tools
badtool=$(sed 's/\..*$//' "$WORK/parity_fields_raw" | sort -u | grep -vxE 'status|quest_status' | tr '\n' ' ')
[ -n "$badtool" ] && fail "parity rows name tools other than status/quest_status: $badtool"

echo "== 4. prior-law immutability (AC8: I01 AND I02 AND I03 AND I04 byte-identical) =="
I01_FILES="DESIGN.md DECISIONS.md artifacts/schema.sql artifacts/seed.sql artifacts/canonical-queries.sql artifacts/check-ddl.sh artifacts/check-constraints.sh artifacts/check-coverage.sh"
I02_FILES="DESIGN.md DECISIONS.md artifacts/schema-i02.sql artifacts/seed-i02.sql artifacts/queries-i02.sql artifacts/check-ddl.sh artifacts/check-constraints.sh artifacts/check-coverage.sh"
I03_FILES="DESIGN.md DECISIONS.md artifacts/schema-i03.sql artifacts/seed-i03.sql artifacts/queries-i03.sql artifacts/check-ddl.sh artifacts/check-constraints.sh artifacts/check-coverage.sh"
I04_FILES="DESIGN.md DECISIONS.md artifacts/check-coverage.sh artifacts/check-failure-modes.sh artifacts/failure-modes.tsv"
missing=""
for f in $I01_FILES; do [ -f "$I01DIR/$f" ] || missing="$missing I01/$f"; done
for f in $I02_FILES; do [ -f "$I02DIR/$f" ] || missing="$missing I02/$f"; done
for f in $I03_FILES; do [ -f "$I03DIR/$f" ] || missing="$missing I03/$f"; done
for f in $I04_FILES; do [ -f "$I04DIR/$f" ] || missing="$missing I04/$f"; done
if [ -n "$missing" ]; then
  fail "ratified prior-law files missing:$missing"
else
  pass "all ratified I01 (8) + I02 (8) + I03 (8) + I04 (5) files present"
fi

if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  fail "worktree is not a git repository — cannot verify prior-law immutability"
else
  head_sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)
  echo "info  worktree HEAD: $head_sha"
  for dir in design/I01-core-model design/I02-cross-quest design/I03-retrieval design/I04-agent-loop; do
    if git -C "$ROOT" diff --quiet HEAD -- "$dir" \
       && [ -z "$(git -C "$ROOT" status --porcelain -- "$dir")" ]; then
      pass "$dir/ byte-identical to ratified state (diff empty, no untracked files)"
    else
      fail "$dir/ DRIFTED from ratified state:"
      git -C "$ROOT" status --porcelain -- "$dir" | sed 's/^/      /'
      git -C "$ROOT" diff --stat HEAD -- "$dir" | sed 's/^/      /'
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
