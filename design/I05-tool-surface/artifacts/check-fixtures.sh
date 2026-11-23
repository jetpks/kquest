#!/usr/bin/env bash
# ============================================================================
# kquest I05 tool-surface — check-fixtures.sh (gate: fixtures-parse, AC2/AC3)
# ----------------------------------------------------------------------------
# Parses every fixture file in artifacts/fixtures/ against the STRICT format
# (paths relative to this script):
#   1. Format (AC2): exactly one `## <tool_name>` header per file, matching
#      the file name, globally unique; a `### canonical` section with a
#      non-empty fenced block; every `### refusal: <class_id>` section has
#      EXACTLY ONE `REFUSAL:` line (inside a fenced block, non-empty text)
#      and exactly one `EVIDENCE:` line; refusal class ids unique per file.
#   2. Evidence resolution (AC3): every EVIDENCE cell resolves — a PoC path
#      that exists (absolute, or worktree-relative; a trailing " §…"
#      citation suffix is stripped), or `schema-law (<name>)` where <name>
#      appears in the I01–I03 DDL artifacts.
#   3. Minimum-law coverage (AC2): fixtures exist for node_add, node_set,
#      edge_add, frontier_add, frontier_close, status, search, list, paths,
#      mass; refusal classes duplicate-label, span-beyond-snapshot,
#      unanchored-span, unknown-tool, non-sliced-read, budget-exceeded each
#      exist somewhere in the set.
#   4. Inventory parity (AC2): every fixture tool name appears in DESIGN.md's
#      fenced `tools` block and vice versa (groups drawn from the six named
#      groups).
# Exit 0 only on full success. macOS bash 3.2 safe.
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXDIR="$SCRIPT_DIR/fixtures"
DESIGN="$SCRIPT_DIR/../DESIGN.md"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SQLFILES="$ROOT/design/I01-core-model/artifacts/schema.sql $ROOT/design/I01-core-model/artifacts/canonical-queries.sql $ROOT/design/I02-cross-quest/artifacts/schema-i02.sql $ROOT/design/I02-cross-quest/artifacts/queries-i02.sql $ROOT/design/I03-retrieval/artifacts/schema-i03.sql $ROOT/design/I03-retrieval/artifacts/queries-i03.sql"
WORK="$(mktemp -d /tmp/kquest_i05_fix.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
fail() { echo "FAIL  $1"; FAILED=$((FAILED+1)); }
pass() { echo "pass  $1"; }

[ -f "$DESIGN" ] || { echo "FAIL  missing DESIGN.md"; exit 1; }
[ -d "$FIXDIR" ] || { echo "FAIL  missing fixtures dir"; exit 1; }

# -- parse one fixture file into structured records -------------------------
parse_fixture() { # $1 = file -> lines on stdout:
  # HDR <name>
  # CANON <0|1>
  # REF <id> <refusal_count> <refusal_in_fence> <text_nonempty> <evidence_count> <evidence>
  awk -v file="$1" '
    BEGIN { sec="top"; infence=0; hdr=0; canon_ok=0 }
    function flush_ref() {
      if (sec == "refusal") printf "REF\t%s\t%d\t%d\t%d\t%d\t%s\n", rid, rcount, rinfence, rlen, ecount, ev
      if (sec == "canonical") printf "CANON\t%d\n", canon_ok
    }
    /^```/ { infence = !infence }
    /^## /  { flush_ref(); hdr++; if (hdr == 1) { hdrname = $2 } else { hdrname = hdrname " " $2 }; sec = "hdr"; next }
    /^### canonical/ { flush_ref(); sec = "canonical"; canon_ok = 0; next }
    /^### refusal: / { flush_ref(); split($0, a, "refusal: "); rid = a[2]; gsub(/[[:space:]]+$/, "", rid); sec = "refusal"; rcount = 0; rinfence = 0; rlen = 0; ecount = 0; ev = ""; next }
    /^### / { flush_ref(); sec = "other"; next }
    {
      if (sec == "refusal" && $0 ~ /^REFUSAL:/) {
        rcount++
        if (infence) rinfence = 1
        t = $0; sub(/^REFUSAL:[[:space:]]*/, "", t)
        if (length(t) > 0) rlen = 1
      }
      if (sec == "refusal" && $0 ~ /^EVIDENCE:/) {
        ecount++
        ev = $0; sub(/^EVIDENCE:[[:space:]]*/, "", ev)
      }
      if (sec == "canonical" && infence && NF > 0) canon_ok = 1
    }
    END { flush_rec() }
    function flush_rec() { flush_ref(); printf "HDR\t%s\t%d\n", hdrname, hdr }
  ' "$1"
}

# -- evidence resolution -----------------------------------------------------
resolve_evidence() { # $1 = evidence cell -> 0 ok / 1 fail
  rev="$1"
  case "$rev" in
    "schema-law ("*)
      name=$(printf '%s' "$rev" | sed 's/^schema-law[[:space:]]*(//; s/)[[:space:]]*$//')
      if [ -z "$name" ]; then
        return 1
      fi
      # judge-F2 fix: a class may cite multiple schema objects, joined
      # with ' + ' — every named object must exist in the DDL artifacts.
      found_all=1
      echo "$name" | tr '+' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | while IFS= read -r nm; do
        [ -z "$nm" ] && continue
        ok=0
        for f in $SQLFILES; do
          if grep -q -- "$nm" "$f"; then ok=1; break; fi
        done
        [ "$ok" -eq 0 ] && { echo "MISSING:$nm"; found_all=0; }
      done > /tmp/kquest_i05_schema_$$
      if [ -s /tmp/kquest_i05_schema_$$ ]; then
        rm -f /tmp/kquest_i05_schema_$$
        return 1
      fi
      rm -f /tmp/kquest_i05_schema_$$
      return 0
      ;;
    "")
      return 1
      ;;
    *)
      path="${rev%% §*}"
      [ -z "$path" ] && return 1
      if [ -e "$path" ]; then return 0; fi
      if [ -e "$ROOT/$path" ]; then return 0; fi
      return 1
      ;;
  esac
}

echo "== 1. per-fixture format + evidence resolution =="
nfiles=0
: > "$WORK/all_headers"
: > "$WORK/all_refs"
for f in "$FIXDIR"/*.md; do
  nfiles=$((nfiles+1))
  base="$(basename "$f" .md)"
  parse_fixture "$f" > "$WORK/records"
  # header
  hline=$(grep -c '^HDR' "$WORK/records")
  if [ "$hline" -ne 1 ]; then
    fail "$base: expected exactly 1 HDR record, got $hline"
    continue
  fi
  hdrname=$(grep '^HDR' "$WORK/records" | cut -f2)
  hdrcount=$(grep '^HDR' "$WORK/records" | cut -f3)
  if [ "$hdrname" != "$base" ]; then
    fail "$base: header '$hdrname' does not match file name"
  fi
  if [ "$hdrcount" -ne 1 ]; then
    fail "$base: has $hdrcount '## ' headers (expected exactly 1)"
  fi
  printf '%s\n' "$hdrname" >> "$WORK/all_headers"
  # canonical
  ncanon=$(grep -c '^CANON' "$WORK/records")
  if [ "$ncanon" -ne 1 ]; then
    fail "$base: expected exactly 1 canonical section, got $ncanon"
  else
    cok=$(grep '^CANON' "$WORK/records" | cut -f2)
    if [ "$cok" -eq 1 ]; then
      pass "$base: canonical call present in a fenced block"
    else
      fail "$base: canonical section has no non-empty fenced block"
    fi
  fi
  # refusals
  nref=0
  grep '^REF' "$WORK/records" > "$WORK/refs"
  while IFS="$(printf '\t')" read -r rtag rid rcount rinfence rlen ecount rev; do
    [ -z "$rid" ] && continue
    nref=$((nref+1))
    printf '%s\t%s\n' "$base" "$rid" >> "$WORK/all_refs"
    ok=1
    [ "$rcount" -eq 1 ] || { fail "$base refusal '$rid': $rcount REFUSAL: lines (expected exactly 1)"; ok=0; }
    [ "$rinfence" -eq 1 ] || { fail "$base refusal '$rid': REFUSAL: line is not inside a fenced block"; ok=0; }
    [ "$rlen" -eq 1 ] || { fail "$base refusal '$rid': REFUSAL text is empty"; ok=0; }
    [ "$ecount" -eq 1 ] || { fail "$base refusal '$rid': $ecount EVIDENCE: lines (expected exactly 1)"; ok=0; }
    if [ "$ecount" -ge 1 ]; then
      if resolve_evidence "$rev"; then
        :
      else
        fail "$base refusal '$rid': EVIDENCE does not resolve: $rev"
        ok=0
      fi
    fi
    [ $ok -eq 1 ] && pass "$base refusal '$rid': one frozen REFUSAL line + EVIDENCE resolves"
  done < "$WORK/refs"
  # per-file class-id uniqueness
  dupids=$(cut -f2 "$WORK/refs" | sort | uniq -d | tr '\n' ' ')
  [ -n "$dupids" ] && fail "$base: duplicate refusal class ids: $dupids"
done
echo "info  $nfiles fixture files parsed"

# global header uniqueness
duph=$(sort "$WORK/all_headers" | uniq -d | tr '\n' ' ')
if [ -n "$duph" ]; then
  fail "tool headers not globally unique: $duph"
else
  pass "all tool headers globally unique ($(wc -l < "$WORK/all_headers" | tr -d ' ') tools)"
fi

echo "== 2. minimum-law coverage =="
for t in node_add node_set edge_add frontier_add frontier_close status search list paths mass; do
  if grep -qx "$t" "$WORK/all_headers"; then
    pass "required fixture present: $t"
  else
    fail "REQUIRED fixture missing: $t"
  fi
done
for c in duplicate-label span-beyond-snapshot unanchored-span unknown-tool non-sliced-read budget-exceeded; do
  n=$(cut -f2 "$WORK/all_refs" | grep -cx "$c")
  if [ "$n" -ge 1 ]; then
    pass "required refusal class present: $c ($n fixture(s))"
  else
    fail "REQUIRED refusal class missing: $c"
  fi
done

echo "== 3. inventory parity (fixtures <-> DESIGN tools block, both directions) =="
awk '/^```tools[[:space:]]*$/ { inm=1; next }
     inm && /^```$/ { inm=0; next }
     inm && NF >= 2 { print $1 "\t" $2 }' "$DESIGN" > "$WORK/inv"
ninv=$(wc -l < "$WORK/inv" | tr -d ' ')
if [ "$ninv" -eq 0 ]; then
  fail "DESIGN.md has no fenced 'tools' inventory block (or it is empty)"
else
  pass "DESIGN inventory: $ninv tools"
fi
cut -f2 "$WORK/inv" | sort -u > "$WORK/inv_names"
sort -u "$WORK/all_headers" > "$WORK/fix_names"
only_inv=$(comm -23 "$WORK/inv_names" "$WORK/fix_names" | tr '\n' ' ')
only_fix=$(comm -13 "$WORK/inv_names" "$WORK/fix_names" | tr '\n' ' ')
if [ -n "$only_inv" ]; then
  fail "tools named in DESIGN inventory without a fixture: $only_inv"
fi
if [ -n "$only_fix" ]; then
  fail "fixture tools missing from DESIGN inventory: $only_fix"
fi
[ -z "$only_inv" ] && [ -z "$only_fix" ] && pass "fixture set == inventory set (1:1 both directions)"
badgroup=$(cut -f1 "$WORK/inv" | sort -u | grep -vxE 'graph|corpus|web|retrieval|report|session' | tr '\n' ' ')
if [ -n "$badgroup" ]; then
  fail "unknown inventory group(s): $badgroup"
else
  pass "all inventory groups are among the six named groups"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "check-fixtures: PASS"
  exit 0
else
  echo "check-fixtures: FAIL ($FAILED problems)"
  exit 1
fi
