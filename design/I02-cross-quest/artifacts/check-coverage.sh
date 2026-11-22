#!/usr/bin/env bash
# ============================================================================
# kquest I02 cross-quest — check-coverage.sh (gate: coverage-checks, AC1/AC5/AC7)
# ----------------------------------------------------------------------------
# Validates, against the files in this directory (paths relative to script):
#   1. DESIGN.md traceability covers R-019..R-027 exactly once each, status
#      DESIGNED or DEFERRED; DEFERRED rows name a destination ENTRY (3..8).
#   2. DECISIONS.md parses: DR-01.. sequential and unique; every record has
#      non-empty Decision / Rationale / Alternatives; OPERATOR-RULING-NEEDED
#      records carry Options + Recommendation.
#   3. ERD/DDL parity for the NEW tables: every entity block in the
#      erDiagram section has a CREATE TABLE in schema-i02.sql and vice
#      versa; every entity named in ERD relationship lines exists in the
#      I01 or I02 schema (no dangling references).
#   4. I01 immutability (AC7): design/I01-core-model/ is byte-identical to
#      its ratified (committed) state — git diff empty AND no untracked
#      additions under that path — and all eight ratified files exist.
# Exit 0 only on full success. POSIX-ish (macOS bash 3.2 safe).
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESIGN="$SCRIPT_DIR/../DESIGN.md"
DECISIONS="$SCRIPT_DIR/../DECISIONS.md"
I02SCHEMA="$SCRIPT_DIR/schema-i02.sql"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
I01DIR="$ROOT/design/I01-core-model"
WORK="$(mktemp -d /tmp/kquest_i02_cov.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
fail() { echo "FAIL  $1"; FAILED=$((FAILED+1)); }
pass() { echo "pass  $1"; }

[ -f "$DESIGN" ]    || { echo "FAIL  missing $DESIGN"; exit 1; }
[ -f "$DECISIONS" ] || { echo "FAIL  missing $DECISIONS"; exit 1; }
[ -f "$I02SCHEMA" ] || { echo "FAIL  missing $I02SCHEMA"; exit 1; }

echo "== 1. traceability: R-019..R-027 in DESIGN.md =="
i=19
while [ $i -le 27 ]; do
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
      if echo "$row" | grep -qE 'ENTRY [3-8]'; then
        pass "$rid DEFERRED -> $(echo "$row" | grep -oE 'ENTRY [3-8]' | head -1)"
      else
        fail "$rid DEFERRED but names no destination ENTRY 3..8"
      fi
      ;;
    *)
      fail "$rid has unrecognized status '$status' (want DESIGNED or DEFERRED)"
      ;;
  esac
  i=$((i+1))
done

echo "== 2. DECISIONS.md structure =="
grep '^## DR-' "$DECISIONS" > "$WORK/headers" || true
nrec=$(wc -l < "$WORK/headers" | tr -d ' ')
if [ "$nrec" -eq 0 ]; then
  fail "no '## DR-' records found in DECISIONS.md"
else
  sed 's/^## DR-//; s/ .*//' "$WORK/headers" > "$WORK/nums"

  uniq_dupes=$(sort "$WORK/nums" | uniq -d | tr -n ' ' 2>/dev/null || true)
  uniq_dupes=$(sort "$WORK/nums" | uniq -d | tr -d '\n' | sed 's/ /,/g')
  seq -w 1 "$nrec" > "$WORK/want"
  if cmp -s "$WORK/want" "$WORK/nums" && [ -z "$uniq_dupes" ]; then
    pass "DR numbering sequential DR-01..DR-$(printf '%02d' "$nrec"), all unique"
  else
    fail "DR numbering not sequential from 01 or not unique (dupes: '$uniq_dupes'): got $(tr '\n' ' ' < "$WORK/nums")"
  fi

  awk -v d="$WORK" '/^## DR-/ { n++; close(f); f = sprintf("%s/blk_%02d", d, n); } f != "" { print > f }' "$DECISIONS"

  k=1
  while [ $k -le "$nrec" ]; do
    dr=$(printf 'DR-%02d' $k)
    blk="$WORK/blk_$(printf '%02d' $k)"
    ok=1
    for field in "Decision" "Rationale" "Alternatives considered"; do
      marker_line=$(grep -n "\*\*${field}:\*\*" "$blk" | head -1 | cut -d: -f1)
      if [ -z "$marker_line" ]; then
        fail "$dr missing '**${field}:**'"
        ok=0
        continue
      fi
      rest=$(sed -n "${marker_line}p" "$blk" | sed "s/.*\*\*${field}:\*\*//")
      if [ -z "$(echo "$rest" | tr -d '[:space:]')" ]; then
        nxt=$(sed -n "$((marker_line+1))p" "$blk")
        if [ -z "$nxt" ] || echo "$nxt" | grep -q '^\*\*[A-Z]'; then
          fail "$dr field '$field' is empty"
          ok=0
        fi
      fi
    done
    [ $ok -eq 1 ] && pass "$dr has non-empty Decision/Rationale/Alternatives"

    if grep -q 'OPERATOR-RULING-NEEDED' "$blk"; then
      if grep -q '\*\*Options:\*\*' "$blk" && grep -q '\*\*Recommendation:\*\*' "$blk"; then
        pass "$dr OPERATOR-RULING-NEEDED with Options + Recommendation"
      else
        fail "$dr flagged OPERATOR-RULING-NEEDED but lacks Options/Recommendation"
      fi
    fi
    k=$((k+1))
  done
fi
echo "info  OPERATOR-RULING-NEEDED records: $(grep -c '^\*\*Status:\*\* OPERATOR-RULING-NEEDED' "$DECISIONS")"

echo "== 3. ERD <-> DDL parity (new tables) =="
# extract ONLY erDiagram mermaid blocks (DESIGN also carries state diagrams)
awk '
  /^```mermaid[[:space:]]*$/ { inm=1; inerd=0; next }
  /^```$/                    { inm=0; inerd=0; next }
  inm && /erDiagram/         { inerd=1; next }
  inerd && $2 == "{"         { print "E " $1 }
  inerd && /--/              { sub(/:.*/, "")
                               for (i = 1; i <= NF; i++)
                                 if ($i ~ /^[a-z_][a-z_0-9]*$/) print "R " $i }
' "$DESIGN" | sort -u > "$WORK/erd_tokens"

awk '/^E /{print $2}' "$WORK/erd_tokens" | sort -u > "$WORK/erd_entities"
awk '/^R /{print $2}' "$WORK/erd_tokens" | sort -u > "$WORK/erd_rel_entities"
sed -n 's/^CREATE TABLE \([a-z_]*\) (.*$/\1/p' "$I02SCHEMA" | sort -u > "$WORK/ddl_tables"
sed -n 's/^CREATE TABLE \([a-z_]*\) (.*$/\1/p' "$I01DIR/artifacts/schema.sql" 2>/dev/null | sort -u > "$WORK/i01_tables"

only_erd=$(comm -23 "$WORK/erd_entities" "$WORK/ddl_tables" | tr '\n' ' ')
only_ddl=$(comm -13 "$WORK/erd_entities" "$WORK/ddl_tables" | tr '\n' ' ')
if [ -z "$only_erd" ] && [ -z "$only_ddl" ]; then
  pass "ERD entity blocks == schema-i02 CREATE TABLE set ($(wc -l < "$WORK/ddl_tables" | tr -d ' ') new tables)"
else
  [ -n "$only_erd" ] && fail "in ERD blocks but not in DDL: $only_erd"
  [ -n "$only_ddl" ] && fail "in DDL but not in ERD blocks: $only_ddl"
fi

cat "$WORK/i01_tables" "$WORK/ddl_tables" | sort -u > "$WORK/all_tables"
dangling=$(comm -23 "$WORK/erd_rel_entities" "$WORK/all_tables" | tr '\n' ' ')
if [ -z "$dangling" ]; then
  pass "ERD relationship entities all resolve (I01 or I02 tables)"
else
  fail "ERD relationships name unknown entities: $dangling"
fi

echo "== 4. I01 immutability (AC7: ratified artifacts byte-identical) =="
I01_FILES="DESIGN.md DECISIONS.md artifacts/schema.sql artifacts/seed.sql artifacts/canonical-queries.sql artifacts/check-ddl.sh artifacts/check-constraints.sh artifacts/check-coverage.sh"
missing=""
for f in $I01_FILES; do
  [ -f "$I01DIR/$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
  fail "ratified I01 files missing:$missing"
else
  pass "all 8 ratified I01 files present"
fi

if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  fail "worktree is not a git repository — cannot verify I01 immutability"
else
  head_sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)
  echo "info  worktree HEAD: $head_sha"
  if git -C "$ROOT" diff --quiet HEAD -- design/I01-core-model \
     && [ -z "$(git -C "$ROOT" status --porcelain -- design/I01-core-model)" ]; then
    pass "design/I01-core-model/ byte-identical to ratified state (diff empty, no untracked files)"
  else
    fail "design/I01-core-model/ DRIFTED from ratified state:"
    git -C "$ROOT" status --porcelain -- design/I01-core-model | sed 's/^/      /'
    git -C "$ROOT" diff --stat HEAD -- design/I01-core-model | sed 's/^/      /'
  fi
fi

if [ "$FAILED" -eq 0 ]; then
  echo "check-coverage: PASS"
  exit 0
else
  echo "check-coverage: FAIL ($FAILED problems)"
  exit 1
fi
