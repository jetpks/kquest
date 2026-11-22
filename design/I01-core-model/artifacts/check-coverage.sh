#!/usr/bin/env bash
# ============================================================================
# kquest I01 core-model — check-coverage.sh (gate: coverage-checks, AC1/AC5)
# ----------------------------------------------------------------------------
# Validates, against the files in this directory (paths relative to script):
#   1. DESIGN.md traceability covers R-001..R-018 exactly once each, with a
#      status of DESIGNED or DEFERRED; DEFERRED rows name a destination
#      ENTRY (2..8).
#   2. DECISIONS.md parses: DR-01.. sequential and unique; every record has
#      non-empty Decision / Rationale / Alternatives; records flagged
#      OPERATOR-RULING-NEEDED carry Options and Recommendation.
#   3. ERD/DDL parity: every entity named in the mermaid ERD has a CREATE
#      TABLE in schema.sql and vice versa (Boundary: no placeholders).
# Exit 0 only on full success. POSIX-ish (macOS bash 3.2 safe).
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESIGN="$SCRIPT_DIR/../DESIGN.md"
DECISIONS="$SCRIPT_DIR/../DECISIONS.md"
SCHEMA="$SCRIPT_DIR/schema.sql"
WORK="$(mktemp -d /tmp/kquest_i01_cov.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
fail() { echo "FAIL  $1"; FAILED=$((FAILED+1)); }
pass() { echo "pass  $1"; }

[ -f "$DESIGN" ]    || { echo "FAIL  missing $DESIGN"; exit 1; }
[ -f "$DECISIONS" ] || { echo "FAIL  missing $DECISIONS"; exit 1; }
[ -f "$SCHEMA" ]    || { echo "FAIL  missing $SCHEMA"; exit 1; }

echo "== 1. traceability: R-001..R-018 in DESIGN.md =="
i=1
while [ $i -le 18 ]; do
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
      if echo "$row" | grep -qE 'ENTRY [2-8]'; then
        pass "$rid DEFERRED -> $(echo "$row" | grep -oE 'ENTRY [2-8]' | head -1)"
      else
        fail "$rid DEFERRED but names no destination ENTRY 2..8"
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

  # numbering sequential from 01, all unique
  uniq_dupes=$(sort "$WORK/nums" | uniq -d | tr '\n' ' ')
  seq -w 1 "$nrec" > "$WORK/want"
  if cmp -s "$WORK/want" "$WORK/nums" && [ -z "$uniq_dupes" ]; then
    pass "DR numbering sequential DR-01..DR-$(printf '%02d' "$nrec"), all unique"
  else
    fail "DR numbering not sequential from 01 or not unique (dupes: '$uniq_dupes'): got $(tr '\n' ' ' < "$WORK/nums")"
  fi

  # per-record structure: split DECISIONS.md into blocks at '## DR-' headers
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
      # non-empty: same-line remainder, else next line must exist and not start a new field
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

echo "== 3. ERD <-> DDL entity parity =="
awk '/^```mermaid$/ { inm=1; next } /^```$/ { inm=0 } inm' "$DESIGN" \
| awk '
    $2 == "{" { print $1; next }                 # entity blocks: "name {"
    /--/ {                                      # relationship lines
      sub(/:.*/, "")                             # drop the quoted label
      for (i = 1; i <= NF; i++)
        if ($i ~ /^[a-z_][a-z_0-9]*$/) print $i
    }
  ' \
| sort -u > "$WORK/erd_entities"
sed -n 's/^CREATE TABLE \([a-z_]*\) (.*$/\1/p' "$SCHEMA" | sort -u > "$WORK/ddl_tables"

only_erd=$(comm -23 "$WORK/erd_entities" "$WORK/ddl_tables" | tr '\n' ' ')
only_ddl=$(comm -13 "$WORK/erd_entities" "$WORK/ddl_tables" | tr '\n' ' ')
if [ -z "$only_erd" ] && [ -z "$only_ddl" ]; then
  pass "ERD entities == CREATE TABLE set ($(wc -l < "$WORK/ddl_tables" | tr -d ' ') tables)"
else
  [ -n "$only_erd" ] && fail "in ERD but not in DDL: $only_erd"
  [ -n "$only_ddl" ] && fail "in DDL but not in ERD: $only_ddl"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "check-coverage: PASS"
  exit 0
else
  echo "check-coverage: FAIL ($FAILED problems)"
  exit 1
fi
