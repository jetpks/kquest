#!/usr/bin/env bash
# ============================================================================
# kquest I08 app-architecture — check-coverage.sh
# (gate: coverage-checks, AC1/AC6/AC7 + map↔DESIGN coherence)
# ----------------------------------------------------------------------------
# Validates, against the files in this directory (paths resolved from the
# script's location; safe from any cwd):
#   1. Traceability (AC1): DESIGN.md's traceability table covers R-073..R-081
#      exactly once each, status DESIGNED (this entry defers nothing).
#   2. DECISIONS.md structure (AC6): DR-01.. sequential and unique; every
#      record has Status/Decision/Rationale/Alternatives considered;
#      OPERATOR-RULING-NEEDED records carry Options + Recommendation; the
#      SEVEN required records present (slice boundaries, worker process
#      model, SSE event envelope, redis's exact role, steering console
#      interaction law, ladder_passes carrier, dev/prod parity posture).
#   3. Map↔DESIGN coherence, BOTH directions: every surface in DESIGN's
#      ```surfaces block appears in the DESIGN body (outside the block) AND
#      in at least one consumption-map consumer cell; and every structural
#      enumeration in DESIGN (the ```events catalog, the ```jobs catalog,
#      the slice table, the UI surface table) is covered by the surfaces
#      block — no prose-only surface, no orphan surface.
#   4. Prior-law immutability (AC7): design/I01..I07 — all SEVEN dirs —
#      byte-identical to the ratified (committed) state (git diff empty,
#      no untracked additions, all tracked files present).
# Exit 0 only on full success. macOS bash 3.2 safe.
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESIGN="$SCRIPT_DIR/../DESIGN.md"
DECISIONS="$SCRIPT_DIR/../DECISIONS.md"
MAP="$SCRIPT_DIR/consumption-map.tsv"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"    # repo root (the worktree)
WORK="$(mktemp -d /tmp/kquest_i08_cov.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
fail() { echo "FAIL  $1"; FAILED=$((FAILED+1)); }
pass() { echo "pass  $1"; }

for f in "$DESIGN" "$DECISIONS" "$MAP"; do
  [ -f "$f" ] || { echo "FAIL  missing $f"; exit 1; }
done

# ---------- shared: split DESIGN.md into surfaces block + body --------------
awk '/^```surfaces$/ {inb=1; next} inb && /^```$/ {inb=0; next}
     inb {print > SRCS; next} {print > BODY}' \
    SRCS="$WORK/surfaces.txt" BODY="$WORK/design_body.md" "$DESIGN"
[ -s "$WORK/surfaces.txt" ] || { echo 'FAIL  no ```surfaces block in DESIGN.md'; exit 1; }
awk '{gsub(/^[ \t]+/, ""); gsub(/[ \t]+$/, ""); if ($0 != "") print}' "$WORK/surfaces.txt" > "$WORK/surfaces.trim"
sort -u "$WORK/surfaces.trim" > "$WORK/surfaces.sorted"

# ---------- 1. traceability R-073..R-081 ------------------------------------
echo "== 1. traceability: R-073..R-081 exactly once, DESIGNED =="
rerr=0
i=73
while [ $i -le 81 ]; do
  rid=$(printf 'R-%03d' $i)
  n=$(grep -c "^| $rid |" "$DESIGN" 2>/dev/null); n=${n:-0}
  if [ "$n" -ne 1 ]; then
    fail "$rid appears $n times in DESIGN.md (expected exactly 1)"; i=$((i+1)); continue
  fi
  row=$(grep "^| $rid |" "$DESIGN")
  if printf '%s' "$row" | grep -q "| DESIGNED |"; then
    :
  elif printf '%s' "$row" | grep -q "| DEFERRED |"; then
    if ! printf '%s' "$row" | grep -qE "DEFERRED \| [^|]+(ENTRY|implementation arc)[^|]*\|"; then
      fail "$rid DEFERRED without a named destination"
    fi
  else
    fail "$rid status is neither DESIGNED nor DEFERRED"
  fi
  i=$((i+1))
done
[ "$rerr" -eq 0 ] && pass "R-073..R-081 present exactly once, all DESIGNED"

# ---------- 2. DECISIONS structure -------------------------------------------
echo "== 2. DECISIONS structure =="
# 2a. headers sequential + unique
awk '/^## DR-[0-9]+/ { match($0, /DR-[0-9]+/); print substr($0, RSTART, RLENGTH) }' \
  "$DECISIONS" > "$WORK/dr.list"
ndr=$(wc -l < "$WORK/dr.list" | tr -d ' ')
if [ "$ndr" -eq 0 ]; then
  fail "no ## DR- records found in DECISIONS.md"
else
  dupdr=$(sort "$WORK/dr.list" | uniq -d)
  [ -n "$dupdr" ] && fail "duplicate DR ids: $dupdr"
  # sequential from DR-01
  exp=1; seqbad=0
  while read -r dr; do
    want=$(printf 'DR-%02d' $exp)
    [ "$dr" = "$want" ] || { fail "DR sequence broken at $dr (expected $want)"; seqbad=1; break; }
    exp=$((exp+1))
  done < "$WORK/dr.list"
  [ "$seqbad" -eq 0 ] && pass "$ndr decision records, sequential DR-01.., unique"
fi

# 2b. per-record fields
awk '
  /^## DR-[0-9]+/ { if (rec != "") check(rec)
    rec = $0; st = dec = rat = alt = orn = opt = rec_ = 0; ornflag = 0; next }
  rec == "" { next }
  /^\*\*Status:\*\*/ { st = 1; if ($0 ~ /OPERATOR-RULING-NEEDED/) ornflag = 1 }
  /^\*\*Decision/ { dec = 1 }
  /^\*\*Rationale:\*\*/ { rat = 1 }
  /^\*\*Alternatives considered:\*\*/ { alt = 1 }
  /^\*\*Options:\*\*/ { opt = 1 }
  /^\*\*Recommendation:\*\*/ { rec_ = 1 }
  { nchars[rec] += length($0) }
  END { if (rec != "") check(rec)
    exit bad }
  function check(r) {
    if (!st) { print "      " r ": missing Status"; bad++ }
    if (!dec) { print "      " r ": missing Decision"; bad++ }
    if (!rat) { print "      " r ": missing Rationale"; bad++ }
    if (!alt) { print "      " r ": missing Alternatives considered"; bad++ }
    if (ornflag) {
      if (!opt) { print "      " r ": OPERATOR-RULING-NEEDED without Options"; bad++ }
      if (!rec_) { print "      " r ": OPERATOR-RULING-NEEDED without Recommendation"; bad++ }
    }
  }
' "$DECISIONS" > "$WORK/dec.fails"; drc=$?
if [ "$drc" -ne 0 ] || [ -s "$WORK/dec.fails" ]; then
  fail "decision-record structure problems:"; cat "$WORK/dec.fails"
else
  pass "every record has Status/Decision/Rationale/Alternatives; ruled records carry Options + Recommendation"
fi

# 2c. the seven required records (by subject, in the DR titles)
tr -d '`' < "$DECISIONS" > "$WORK/decisions.noticks"
: > "$WORK/missing.req"
for t in "slice boundaries" "worker process model" "SSE event envelope" "Redis's exact role" "steering console interaction law" "ladder_passes durable carrier" "dev/prod parity posture"; do
  grep -qi "^## DR-[0-9]* .*$t" "$WORK/decisions.noticks" || echo "      missing required record: $t" >> "$WORK/missing.req"
done
if [ -s "$WORK/missing.req" ]; then
  fail "required decision records missing:"; cat "$WORK/missing.req"
else
  pass "all seven required records present"
fi

# ---------- 3. map↔DESIGN coherence, both directions ------------------------
echo "== 3. map↔DESIGN coherence (both directions) =="
# 3a. every surfaces-block token appears in the DESIGN body
: > "$WORK/body.missing"
while read -r tok; do
  grep -qF "$tok" "$WORK/design_body.md" || echo "      $tok not in DESIGN body" >> "$WORK/body.missing"
done < "$WORK/surfaces.trim"
if [ -s "$WORK/body.missing" ]; then
  fail "surfaces not in DESIGN body:"; cat "$WORK/body.missing"
else
  pass "every surface token appears in the DESIGN body (outside the block)"
fi

# 3b. every surfaces-block token appears in ≥1 map consumer cell
awk -F'\t' -v SRCS="$WORK/surfaces.sorted" '
  BEGIN { while ((getline line < SRCS) > 0) used[line] = 0 }
  NR > 1 && NF == 3 {
    sep = index($2, " — ")
    if (sep > 0) { tok = substr($2, 1, sep - 1); if (tok in used) used[tok]++ }
  }
  END { bad = 0
    for (t in used) if (used[t] == 0) { print "      " t " never consumes anything in the map"; bad++ }
    exit (bad ? 1 : 0) }
' "$MAP" > "$WORK/map.missing"; mrc=$?
if [ "$mrc" -ne 0 ] || [ -s "$WORK/map.missing" ]; then
  fail "surfaces never consumed by the map:"; cat "$WORK/map.missing"
else
  ns=$(wc -l < "$WORK/surfaces.sorted" | tr -d ' ')
  pass "all $ns surface tokens consumed by the map (reverse direction)"
fi

# 3c. DESIGN's structural enumerations are covered by the surfaces block
#     (events catalog, jobs catalog, slice table, UI surface table)
awk '/^```events$/ {inb=1; next} inb && /^```$/ {inb=0} inb {print}' "$DESIGN" \
  | awk '{gsub(/^[ \t]+/, ""); gsub(/[ \t]+$/, ""); if ($0 != "") print}' > "$WORK/events.txt"
awk '/^```jobs$/ {inb=1; next} inb && /^```$/ {inb=0} inb {print}' "$DESIGN" \
  | awk '{gsub(/^[ \t]+/, ""); gsub(/[ \t]+$/, ""); if ($0 != "") print}' > "$WORK/jobs.txt"
grep -E '^\| `slices/[a-z]+`' "$DESIGN" | sed -E 's/^\| `([^`]+)`.*/\1/' > "$WORK/slices.txt"
grep -E '^\| `(dashboard|quest view|frontier inspector|graph browser|report view|steering console|cost views|alerting|interactive briefing)`' "$DESIGN" \
  | sed -E 's/^\| `([^`]+)`.*/\1/' > "$WORK/uisurf.txt"
: > "$WORK/enum.missing"
for f in events jobs slices uisurf; do
  while read -r tok; do
    grep -qxF "$tok" "$WORK/surfaces.sorted" || echo "      [$f] $tok in DESIGN but not in the surfaces block" >> "$WORK/enum.missing"
  done < "$WORK/$f.txt"
done
if [ -s "$WORK/enum.missing" ]; then
  fail "DESIGN enumerations not covered by the surface vocabulary:"; cat "$WORK/enum.missing"
else
  pass "event catalog, job catalog, slice table, UI table all covered by the surfaces block"
fi

# ---------- 4. prior-law immutability (AC7) ----------------------------------
echo "== 4. prior-law immutability: I01..I07 =="
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  fail "$ROOT is not a git repository — cannot verify prior-law immutability"
else
  head_sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)
  echo "      HEAD $head_sha"
  drift=0
  for n in 01 02 03 04 05 06 07; do
    dir=$(ls -d "$ROOT"/design/I$n-* 2>/dev/null | head -1)
    [ -z "$dir" ] && { fail "design/I$n-* directory missing"; drift=1; continue; }
    dname=$(basename "$dir")
    gpath="design/$dname"
    d=""
    git -C "$ROOT" diff --quiet HEAD -- "$gpath" || d="$d diff"
    [ -n "$(git -C "$ROOT" status --porcelain -- "$gpath")" ] && d="$d status"
    nfiles=$(git -C "$ROOT" ls-files -- "$gpath" | wc -l | tr -d ' ')
    for tf in $(git -C "$ROOT" ls-files -- "$gpath"); do
      [ -e "$ROOT/$tf" ] || d="$d missing:$tf"
    done
    if [ -n "$d" ] || [ "$nfiles" -eq 0 ]; then
      fail "$dname not clean:$d"
      git -C "$ROOT" status --porcelain -- "$gpath" | sed 's/^/      /'
      git -C "$ROOT" diff --stat HEAD -- "$gpath" | sed 's/^/      /'
      drift=1
    else
      echo "      $dname clean ($nfiles tracked files)"
    fi
  done
  [ "$drift" -eq 0 ] && pass "all SEVEN prior-law dirs byte-identical to HEAD"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "OK  coverage: R-073..R-081 designed; DECISIONS well-formed; map↔DESIGN coherent; prior law immutable"
  exit 0
else
  echo "NOK  $FAILED check group(s) failed"
  exit 1
fi
