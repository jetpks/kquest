#!/usr/bin/env bash
# ============================================================================
# kquest I04 agent-loop — check-coverage.sh (gate: coverage-checks,
# AC1/AC4/AC6/AC7)
# ----------------------------------------------------------------------------
# Validates, against the files in this directory (paths relative to script):
#   1. Traceability (AC1): DESIGN.md's traceability table covers
#      R-038..R-046 exactly once each, status DESIGNED or DEFERRED; a DEFERRED
#      row names a destination ENTRY (5..8).
#   2. DECISIONS.md structure (AC6): DR-01.. sequential and unique; every
#      record has non-empty Decision / Rationale / Alternatives considered;
#      OPERATOR-RULING-NEEDED records carry Options + Recommendation; the six
#      REQUIRED records are present (pause mechanics, one-writer enforcement
#      point, transcript-ceiling policy, seed default, subagent tool-surface
#      restriction, context budget advisory by default).
#   3. Architecture <-> handling-table parity (AC4): every component named in
#      DESIGN.md's component registry (the fenced `components` block in the
#      architecture section) appears in failure-modes.tsv's `destination`
#      column (allowing comma-separated lists), and every destination value
#      resolves to a registered component — both directions.
#   4. Prior-law immutability (AC7): design/I01-core-model/, design/I02-
#      cross-quest/ AND design/I03-retrieval/ are byte-identical to their
#      ratified (committed) state — git diff empty vs worktree HEAD AND no
#      untracked additions under any of the three — and all ratified files
#      are present.
# Exit 0 only on full success. macOS bash 3.2 safe.
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESIGN="$SCRIPT_DIR/../DESIGN.md"
DECISIONS="$SCRIPT_DIR/../DECISIONS.md"
TSV="$SCRIPT_DIR/failure-modes.tsv"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
I01DIR="$ROOT/design/I01-core-model"
I02DIR="$ROOT/design/I02-cross-quest"
I03DIR="$ROOT/design/I03-retrieval"
WORK="$(mktemp -d /tmp/kquest_i04_cov.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
fail() { echo "FAIL  $1"; FAILED=$((FAILED+1)); }
pass() { echo "pass  $1"; }

for f in "$DESIGN" "$DECISIONS" "$TSV"; do
  [ -f "$f" ] || { echo "FAIL  missing $f"; exit 1; }
done

echo "== 1. traceability: R-038..R-046 in DESIGN.md =="
i=38
while [ $i -le 46 ]; do
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
      if echo "$row" | grep -qE 'ENTRY [5-8]|implementation arc entry 0'; then
        pass "$rid DEFERRED -> $(echo "$row" | grep -oE 'ENTRY [5-8]|implementation arc entry 0' | head -1)"
      else
        fail "$rid DEFERRED but names no destination ENTRY 5..8 (or gems entry 0)"
      fi
      ;;
    *)
      fail "$rid has unrecognized status '$status' (want DESIGNED or DEFERRED)"
      ;;
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
    /^## /    { close(f); f = ""; next }
    f != ""  { print > f }
  ' "$DECISIONS"

  k=1
  while [ $k -le "$nrec" ]; do
    dr=$(printf 'DR-%02d' $k)
    hdr=$(sed -n "${k}p" "$WORK/headers")
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
  for topic in "pause mechanics:Pause" "one-writer enforcement point:one-writer" \
               "transcript-ceiling policy:transcript-ceiling" "seed default:seed default" \
               "subagent tool-surface restriction:subagent tool-surface" \
               "context budget advisory by default:advisory by default"; do
    name="${topic%%:*}"; token="${topic#*:}"
    if grep -i -q -- "$token" "$WORK/headers"; then
      pass "required record present: $name (header token '$token')"
    else
      fail "required record MISSING: $name (no DR header matching '$token')"
    fi
  done
fi
echo "info  OPERATOR-RULING-NEEDED records: $(grep -c '\*\*Status:\*\* OPERATOR-RULING-NEEDED' "$DECISIONS")"

echo "== 3. architecture <-> handling-table parity (AC4) =="
# The component registry: the fenced `components` block in DESIGN.md.
awk '/^```components[[:space:]]*$/ { inm=1; next }
     inm && /^```$/ { inm=0; next }
     inm && NF > 0 { print $1 }' "$DESIGN" | sort -u > "$WORK/components"
ncomp=$(wc -l < "$WORK/components" | tr -d ' ')
if [ "$ncomp" -eq 0 ]; then
  fail "DESIGN.md has no fenced 'components' registry block (or it is empty)"
else
  pass "component registry: $ncomp components ($(tr '\n' ' ' < "$WORK/components"))"
fi

# Destination values: split comma-separated cells, collect the set.
awk -F'\t' 'NR>1 { n = split($7, arr, ","); for (i=1;i<=n;i++) print arr[i] }' "$TSV" \
  | sed 's/[[:space:]]//g' | sort -u > "$WORK/dests"
ndest=$(wc -l < "$WORK/dests" | tr -d ' ')

only_design=$(comm -23 "$WORK/components" "$WORK/dests" | tr '\n' ' ')
only_tsv=$(comm -13 "$WORK/components" "$WORK/dests" | tr '\n' ' ')
if [ -z "$only_design" ] && [ -z "$only_tsv" ]; then
  pass "component set == destination set ($ncomp components, $ndest distinct destinations)"
else
  [ -n "$only_design" ] && fail "components named in the architecture but never a destination: $only_design"
  [ -n "$only_tsv" ] && fail "destination values not registered as components: $only_tsv"
fi

# Every component's destination row must also carry a non-empty signature
# row (structural sanity): the TSV gate covers cell content; here we only
# confirm each registered component is referenced at least once per row set.
while read -r c; do
  [ -z "$c" ] && continue
  cnt=$(awk -F'\t' -v comp="$c" 'NR>1 { n = split($7, arr, ","); for (i=1;i<=n;i++) { gsub(/[[:space:]]/, "", arr[i]); if (arr[i] == comp) k++ } } END { print k+0 }' "$TSV")  # judge F6: destination-COLUMN-scoped, not whole-row grep
  if [ "$cnt" -ge 1 ]; then
    pass "component $c appears in the destination column ($cnt row(s))"
  else
    fail "component $c never appears in the destination column"
  fi
done < "$WORK/components"

echo "== 4. prior-law immutability (AC7: I01 AND I02 AND I03 byte-identical) =="
I01_FILES="DESIGN.md DECISIONS.md artifacts/schema.sql artifacts/seed.sql artifacts/canonical-queries.sql artifacts/check-ddl.sh artifacts/check-constraints.sh artifacts/check-coverage.sh"
I02_FILES="DESIGN.md DECISIONS.md artifacts/schema-i02.sql artifacts/seed-i02.sql artifacts/queries-i02.sql artifacts/check-ddl.sh artifacts/check-constraints.sh artifacts/check-coverage.sh"
I03_FILES="DESIGN.md DECISIONS.md artifacts/schema-i03.sql artifacts/seed-i03.sql artifacts/queries-i03.sql artifacts/check-ddl.sh artifacts/check-constraints.sh artifacts/check-coverage.sh"
missing=""
for f in $I01_FILES; do [ -f "$I01DIR/$f" ] || missing="$missing I01/$f"; done
for f in $I02_FILES; do [ -f "$I02DIR/$f" ] || missing="$missing I02/$f"; done
for f in $I03_FILES; do [ -f "$I03DIR/$f" ] || missing="$missing I03/$f"; done
if [ -n "$missing" ]; then
  fail "ratified prior-law files missing:$missing"
else
  pass "all 8 ratified I01 files + all 8 ratified I02 files + all 8 ratified I03 files present"
fi

if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  fail "worktree is not a git repository — cannot verify prior-law immutability"
else
  head_sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)
  echo "info  worktree HEAD: $head_sha"
  for dir in design/I01-core-model design/I02-cross-quest design/I03-retrieval; do
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
