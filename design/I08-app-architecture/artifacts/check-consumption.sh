#!/usr/bin/env bash
# ============================================================================
# kquest I08 app-architecture — check-consumption.sh
# (gate: consumption-checks, AC2/AC3)
# ----------------------------------------------------------------------------
# Validates artifacts/consumption-map.tsv against the REAL I01–I07 artifacts
# (paths resolved from this script's location; safe from any cwd):
#   1. Structure: header exact; 3 TAB columns; col1 owns an iteration
#      (I01..I07); col3 in the kind enum; no duplicate prior_artifact cells.
#   2. Consumer cells: "<surface> — <detail>", surface ∈ DESIGN.md's
#      ```surfaces block, detail non-empty, kind matches the surface's
#      class, and the surface token appears in the DESIGN.md BODY (outside
#      the surfaces block itself) — a consumer that names no real DESIGN
#      surface fails.
#   3. prior_artifact cells RESOLVE: every file basename cited exists under
#      the owning iteration's directory.
#   4. DERIVED MINIMUM coverage: the required artifact set is derived FROM
#      the prior artifacts themselves (I01–I03 CREATE TABLE/VIEW names, the
#      I01 canonical query objects, the I02/I03 query-family tokens, the
#      I04 FM rows + component registry + session-law DRs, the I05 fixture
#      files + parity fields + tool-law anchors, the I06 SR ids + config
#      keys + transition (from_phase,event) pairs + contract anchors, the
#      I07 tw_* predicates + metrics + blind spots + workflow anchors) —
#      every required name must appear in EXACTLY ONE map row owned by its
#      iteration (extended-boundary match: letters/digits/underscore/dot
#      are name chars, so status.claims never counts as claims), and every
#      transition pair must be matched by EXACTLY ONE I06 row carrying both
#      tokens. Fixed anchor tokens are grep-verified in the named artifact
#      at derivation time — a token the prior law lacks fails the checker.
# Exit 0 only on full success. macOS bash 3.2 safe.
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAP="$SCRIPT_DIR/consumption-map.tsv"
DESIGN="$SCRIPT_DIR/../DESIGN.md"
D="$(cd "$SCRIPT_DIR/../.." && pwd)"   # design/ (I01..I07 live here)
WORK="$(mktemp -d /tmp/kquest_i08_consume.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

I01="$D/I01-core-model"; I02="$D/I02-cross-quest"; I03="$D/I03-retrieval"
I04="$D/I04-agent-loop"; I05="$D/I05-tool-surface"; I06="$D/I06-quest-process"
I07="$D/I07-assurance"

FAILED=0
fail() { echo "FAIL  $1"; FAILED=$((FAILED+1)); }
pass() { echo "pass  $1"; }

for f in "$MAP" "$DESIGN"; do
  [ -f "$f" ] || { echo "FAIL  missing $f"; exit 1; }
done
for d in "$I01" "$I02" "$I03" "$I04" "$I05" "$I06" "$I07"; do
  [ -d "$d" ] || { echo "FAIL  missing prior-law dir $d"; exit 1; }
done

# ---------- shared: split DESIGN.md into surfaces block + body --------------
awk '/^```surfaces$/ {inb=1; next} inb && /^```$/ {inb=0; next}
     inb {print > SRCS; next} {print > BODY}' \
    SRCS="$WORK/surfaces.txt" BODY="$WORK/design_body.md" "$DESIGN"
[ -s "$WORK/surfaces.txt" ] || { echo 'FAIL  no ```surfaces block in DESIGN.md'; exit 1; }
awk '{gsub(/^[ \t]+/, ""); gsub(/[ \t]+$/, ""); if ($0 != "") print}' "$WORK/surfaces.txt" | sort -u > "$WORK/surfaces.sorted"

# ---------- the kind class table (in step with the DESIGN surface index) ----
cat > "$WORK/kind.map" <<'EOF'
slices/corpus	slice
slices/graph	slice
slices/retrieval	slice
slices/quest	slice
slices/reports	slice
slices/watch	slice
phase runner	job
fetch→chunk→embed pipeline	job
re-chunk/re-embed job	job
transcript watcher	job
reaper sweep	job
cap telemetry job	job
worker registry	job
launch gate	job
quest.state	sse-event
quest.stop	sse-event
phase.state	sse-event
session.state	sse-event
tool.event	sse-event
spend.tick	sse-event
frontier.mass	sse-event
assurance_alert	sse-event
subagent.run	sse-event
watcher.bytes	sse-event
dashboard	ui-surface
quest view	ui-surface
frontier inspector	ui-surface
graph browser	ui-surface
report view	ui-surface
steering console	ui-surface
cost views	ui-surface
alerting	ui-surface
interactive briefing	ui-surface
fetch-layer budget boundary	security
credentials boundary	security
audit completeness	security
process containment	security
deployment shape	deployment
dev/prod parity	deployment
PoC fixtures plan	fixtures-plan
arc entry 0	arc-entry
arc entry 1	arc-entry
arc entry 2	arc-entry
arc entry 3	arc-entry
arc entry 4	arc-entry
arc entry 5	arc-entry
EOF

# surface block must equal the kind table exactly (vocabulary closed both ways)
if ! diff "$WORK/surfaces.sorted" <(cut -f1 "$WORK/kind.map" | sort -u) > "$WORK/voc.diff" 2>&1; then
  fail "surfaces block and kind class table diverge:"; sed 's/^/      /' "$WORK/voc.diff"
  exit 1
else
  pass "surface vocabulary closed (DESIGN block == kind table)"
fi

# ---------- 1./2. structure + consumer cells (single pass) ------------------
echo "== 1–2. structure, consumer surfaces, kinds =="
awk -F'\t' -v SRCS="$WORK/surfaces.sorted" -v KM="$WORK/kind.map" -v BODY="$WORK/design_body.md" '
  BEGIN {
    while ((getline line < SRCS) > 0) surf[line] = 1
    while ((getline line < KM) > 0) { split(line, k, "\t"); kind[k[1]] = k[2] }
    while ((getline line < BODY) > 0) body = body "\n" line
    ndup = 0
  }
  function bmatch(s, tok,   n, from, hit, pre, post) {
    n = length(tok); from = 1
    while (1) {
      hit = index(substr(s, from), tok)
      if (hit == 0) return 0
      hit = hit + from - 1
      pre = (hit == 1) ? "" : substr(s, hit - 1, 1)
      post = substr(s, hit + n, 1)
      if (okc(pre) && okc(post)) return 1
      from = hit + 1
    }
  }
  function okc(c) { if (c == "") return 1; return (c !~ /[A-Za-z0-9_.]/) }
  NR == 1 {
    if ($0 != "prior_artifact\ti08_consumer\tconsumer_kind")
      print "FAIL  header row is not the exact 3-column header"
    next
  }
  NF != 3 { print "FAIL  line " NR ": " NF " columns (expected 3)"; next }
  {
    n++
    if ($1 !~ /^I0[1-7] /) print "FAIL  line " NR ": col1 does not start with an I01..I07 owner"
    if (seen[$1]++) print "FAIL  line " NR ": duplicate prior_artifact cell"
    sep = index($2, " — ")
    if (sep == 0) { print "FAIL  line " NR ": consumer cell lacks \"<surface> — <detail>\""; next }
    tok = substr($2, 1, sep - 1)
    detail = substr($2, sep + 3)
    if (!(tok in surf)) print "FAIL  line " NR ": consumer surface \"" tok "\" not in the DESIGN surfaces block"
    else {
      if (!bmatch(body, tok)) print "FAIL  line " NR ": surface \"" tok "\" not found in DESIGN body"
      if (!(tok in kind)) print "FAIL  line " NR ": surface \"" tok "\" has no kind class"
      else if (kind[tok] != $3) print "FAIL  line " NR ": kind \"" $3 "\" mismatches surface \"" tok "\" (" kind[tok] ")"
    }
    if (detail == "") print "FAIL  line " NR ": empty consumer detail"
    if ($3 !~ /^(slice|job|sse-event|ui-surface|security|deployment|fixtures-plan|arc-entry)$/)
      print "FAIL  line " NR ": kind \"" $3 "\" not in enum"
  }
  END { printf "      %d map rows parsed\n", n }
' "$MAP" > "$WORK/struct.txt"
cat "$WORK/struct.txt"
if grep -q "^FAIL" "$WORK/struct.txt"; then
  fail "structure/consumer problems (above)"
else
  pass "structure + consumer cells + kinds + no duplicate cells"
fi

# ---------- 3. prior_artifact cells resolve (file basenames) ---------------
echo "== 3. prior_artifact resolution =="
awk -F'\t' 'NR > 1 && NF == 3 { print NR "\t" $1 }' "$MAP" > "$WORK/col1.txt"
: > "$WORK/resolve.fails"
while IFS=$'\t' read -r ln cell; do
  owner=$(printf '%s' "$cell" | cut -d' ' -f1)
  case "$owner" in
    I01) od="$I01";; I02) od="$I02";; I03) od="$I03";; I04) od="$I04";;
    I05) od="$I05";; I06) od="$I06";; I07) od="$I07";; *) od="";;
  esac
  [ -n "$od" ] || { echo "line $ln: no owner dir" >> "$WORK/resolve.fails"; continue; }
  printf '%s' "$cell" | grep -oE '[A-Za-z0-9_.-]+\.(sh|sql|tsv|md)' | sort -u | while read -r base; do
    if [ -z "$(find "$od" -name "$base" -type f -print 2>/dev/null | head -1)" ]; then
      echo "line $ln: basename $base not found under $owner" >> "$WORK/resolve.fails"
    fi
  done
done < "$WORK/col1.txt"
if [ -s "$WORK/resolve.fails" ]; then
  fail "unresolved file references:"; sed 's/^/      /' "$WORK/resolve.fails"
else
  pass "every cited file basename resolves under its owning iteration"
fi

# ---------- 4. derived minimum ---------------------------------------------
echo "== 4. derived minimum (from the prior artifacts themselves) =="
REQ="$WORK/required.tsv"; : > "$REQ"

# 4a. tables + views from the three schema files
for spec in "I01|$I01/artifacts/schema.sql" "I02|$I02/artifacts/schema-i02.sql" "I03|$I03/artifacts/schema-i03.sql"; do
  owner=${spec%%|*}; f=${spec#*|}
  grep -E '^CREATE (TABLE|VIEW|MATERIALIZED VIEW) |^CREATE OR REPLACE VIEW ' "$f" \
    | sed -E 's/^CREATE (OR REPLACE )?(TABLE|VIEW|MATERIALIZED VIEW) +([A-Za-z0-9_]+).*/\3/' \
    | sort -u | while read -r n; do [ -n "$n" ] && printf '%s\t%s\n' "$owner" "$n" >> "$REQ"; done
done

# 4b. I01 canonical query objects (temp tables q*)
grep -E '^CREATE TEMP TABLE q' "$I01/artifacts/canonical-queries.sql" \
  | sed -E 's/^CREATE TEMP TABLE +([a-z0-9_]+).*/\1/' | sort -u \
  | while read -r n; do printf 'I01\t%s\n' "$n" >> "$REQ"; done

# 4c. fixed anchor tokens — each VERIFIED to grep in the named prior file
#     (owner, file, grep -E pattern, token); a token the artifact lacks
#     fails the checker (derivation broken), never passes silently.
emit_fixed() {
  if grep -qiE "$3" "$2" 2>/dev/null; then
    printf '%s\t%s\n' "$1" "$4" >> "$REQ"
  else
    echo "FAIL  required anchor \"$4\" does not grep in $2 — derivation broken" >&2
    exit 1
  fi
}
for t in M1 M2 M3 M4 X1 B1; do emit_fixed "I02" "$I02/artifacts/queries-i02.sql" "^-- *$t\b" "$t"; done
emit_fixed "I02" "$I02/DESIGN.md" "visibility and sharing" "visibility and sharing"
emit_fixed "I03" "$I03/artifacts/queries-i03.sql" "RRF" "RRF"
emit_fixed "I03" "$I03/artifacts/queries-i03.sql" "near-dup" "near-dup"
emit_fixed "I03" "$I03/DESIGN.md" "registration, generation, retirement|registration/generation/retirement|Retirement" "registration"
emit_fixed "I01" "$I01/DECISIONS.md" "^## DR-12 " "DR-12"
for t in DR-04 DR-05 DR-06 DR-07; do emit_fixed "I04" "$I04/DECISIONS.md" "^## $t " "$t"; done
emit_fixed "I04" "$I04/DESIGN.md" "component registry" "component registry"
emit_fixed "I04" "$I04/DESIGN.md" "kill semantics" "kill semantics"
emit_fixed "I04" "$I04/DESIGN.md" "one-writer" "one-writer enforcement"
emit_fixed "I05" "$I05/DESIGN.md" "tool inventory" "tool inventory"
emit_fixed "I05" "$I05/DESIGN.md" "restricted-tool profiles" "restricted-tool profiles"
emit_fixed "I05" "$I05/DECISIONS.md" "^## DR-07 " "DR-07"
emit_fixed "I05" "$I05/DECISIONS.md" "^## DR-10 " "DR-10"
emit_fixed "I06" "$I06/DESIGN.md" "per-phase contracts|Per-phase contracts" "per-phase contracts"
emit_fixed "I06" "$I06/DESIGN.md" "law overlays" "law overlays"
emit_fixed "I06" "$I06/DESIGN.md" "model routing|Model routing" "model routing"
emit_fixed "I06" "$I06/DESIGN.md" "never-reportless" "never-reportless"
for t in DR-01 DR-02 DR-07 DR-08; do emit_fixed "I07" "$I07/DECISIONS.md" "^## $t " "$t"; done
emit_fixed "I07" "$I07/DESIGN.md" "guarantee map" "guarantee map"
emit_fixed "I07" "$I07/DESIGN.md" "qualification ladder" "qualification ladder"
emit_fixed "I07" "$I07/DESIGN.md" "conflict adjudication" "conflict adjudication"
emit_fixed "I07" "$I07/DESIGN.md" "verification machinery|Verification machinery" "verification machinery"

# 4d. I04 FM rows
awk -F'\t' 'NR > 1 && $1 != "" { print $1 }' "$I04/artifacts/failure-modes.tsv" \
  | while read -r fm; do printf 'I04\t%s\n' "$fm" >> "$REQ"; done

# 4e. I04 component registry (```components block)
awk '/^```components$/ {inb=1; next} inb && /^```$/ {inb=0} inb {print}' "$I04/DESIGN.md" \
  | while read -r c; do [ -n "$c" ] && printf 'I04\t%s\n' "$c" >> "$REQ"; done

# 4f. I05 fixture files (cited as <stem>.md)
ls "$I05/artifacts/fixtures/"*.md | while read -r f; do
  printf 'I05\t%s\n' "$(basename "$f")" >> "$REQ"
done

# 4g. I05 parity fields (```parity block, last cell)
awk '/^```parity$/ {inb=1; next} inb && /^```$/ {inb=0} inb {
  if (index($0, "|") > 0) {
    line = $0
    n = split(line, a, /\|/)
    f = a[n]; gsub(/^[ \t]+|[ \t]+$/, "", f)
    if (f != "" && f !~ /^-+$/) print f
  }
}' "$I05/DESIGN.md" | sort -u | while read -r f; do printf 'I05\t%s\n' "$f" >> "$REQ"; done

# 4h. I06 SR ids + config keys
awk -F'\t' 'NR > 1 { print $1; print $8 }' "$I06/artifacts/stop-rules.tsv" \
  | while read -r k; do [ -n "$k" ] && printf 'I06\t%s\n' "$k" >> "$REQ"; done

# 4i. I06 transition (from_phase, event) pairs
awk -F'\t' 'NR > 1 && NF >= 2 { print $1 "\t" $2 }' "$I06/artifacts/transitions.tsv" \
  | sort -u > "$WORK/pairs.tsv"

# 4j. I07 tw_* predicates
grep -E '^CREATE OR REPLACE VIEW tw_' "$I07/artifacts/tripwires-i07.sql" \
  | sed -E 's/^CREATE OR REPLACE VIEW +([a-z_]+).*/\1/' | sort -u \
  | while read -r n; do printf 'I07\t%s\n' "$n" >> "$REQ"; done

# 4k. I07 metrics (§5 table) + blind spots (§6 table), first cells
sed -n '/^## 5\. Metric definitions/,/^## 6\./p' "$I07/DESIGN.md" | grep '^|' \
  | cut -d'|' -f2 | awk '{gsub(/[ \t]+/, ""); if ($0 != "" && $0 !~ /^-+$/ && $0 != "Metric") print}' \
  | while read -r m; do printf 'I07\t%s\n' "$m" >> "$REQ"; done
sed -n '/^## 6\. Blind-spot metrics/,/^## 7\./p' "$I07/DESIGN.md" | grep '^|' \
  | cut -d'|' -f2 | awk '{gsub(/[ \t]+/, ""); if ($0 != "" && $0 !~ /^-+$/ && $0 != "Blindspot") print}' \
  | while read -r m; do printf 'I07\t%s\n' "$m" >> "$REQ"; done

sort -u "$REQ" -o "$REQ"
nreq=$(wc -l < "$REQ" | tr -d ' ')
echo "      derived minimum: $nreq required (owner, token) pairs"

# coverage + exactly-once over the map (owner-scoped, extended boundaries)
awk -F'\t' -v REQ="$REQ" '
  BEGIN {
    while ((getline line < REQ) > 0) {
      split(line, r, "\t"); req[r[1], r[2]] = 0
      seenowner[r[1]] = 1
      toks[r[1]] = toks[r[1]] "\n" r[2]
    }
  }
  function bmatch(s, tok,   n, from, hit, pre, post) {
    n = length(tok); from = 1
    while (1) {
      hit = index(substr(s, from), tok)
      if (hit == 0) return 0
      hit = hit + from - 1
      pre = (hit == 1) ? "" : substr(s, hit - 1, 1)
      post = substr(s, hit + n, 1)
      if (okc(pre) && okc(post)) return 1
      from = hit + 1
    }
  }
  function okc(c) { if (c == "") return 1; return (c !~ /[A-Za-z0-9_.]/) }
  NR > 1 && NF == 3 {
    owner = $1; sub(/ .*/, "", owner)
    if (!(owner in seenowner)) next
    split(toks[owner], tlist, "\n")
    for (i = 1; i <= length(tlist); i++) {
      tk = tlist[i]
      if (tk == "") continue
      if (bmatch($1, tk)) req[owner, tk]++
    }
  }
  END {
    bad = 0
    for (k in req) {
      split(k, parts, SUBSEP)
      if (req[k] == 0) { print "      missing: " parts[1] " " parts[2]; bad++ }
      else if (req[k] > 1) { print "      consumed " req[k] "x: " parts[1] " " parts[2]; bad++ }
    }
    exit (bad ? 1 : 0)
  }
' "$MAP" > "$WORK/cover.txt"; rc=$?
if [ $rc -ne 0 ] || [ -s "$WORK/cover.txt" ]; then
  fail "derived-minimum coverage gaps/duplicates:"; cat "$WORK/cover.txt"
else
  pass "all $nreq required artifacts consumed exactly once"
fi

# transition pairs: exactly one I06 row carrying both tokens
awk -F'\t' -v PAIRS="$WORK/pairs.tsv" '
  BEGIN { while ((getline line < PAIRS) > 0) { split(line, p, "\t"); cnt[p[1], p[2]] = 0 } }
  function bmatch(s, tok,   n, from, hit, pre, post) {
    n = length(tok); from = 1
    while (1) {
      hit = index(substr(s, from), tok)
      if (hit == 0) return 0
      hit = hit + from - 1
      pre = (hit == 1) ? "" : substr(s, hit - 1, 1)
      post = substr(s, hit + n, 1)
      if (okc(pre) && okc(post)) return 1
      from = hit + 1
    }
  }
  function okc(c) { if (c == "") return 1; return (c !~ /[A-Za-z0-9_.]/) }
  NR > 1 && NF == 3 {
    owner = $1; sub(/ .*/, "", owner)
    if (owner != "I06") next
    for (k in cnt) {
      split(k, parts, SUBSEP)
      if (bmatch($1, parts[1]) && bmatch($1, parts[2])) cnt[k]++
    }
  }
  END {
    bad = 0
    for (k in cnt) {
      split(k, parts, SUBSEP)
      if (cnt[k] == 0) { print "      pair uncovered: (" parts[1] ", " parts[2] ")"; bad++ }
      else if (cnt[k] > 1) { print "      pair matched " cnt[k] "x: (" parts[1] ", " parts[2] ")"; bad++ }
    }
    exit (bad ? 1 : 0)
  }
' "$MAP" > "$WORK/paircover.txt"; rc=$?
if [ $rc -ne 0 ] || [ -s "$WORK/paircover.txt" ]; then
  fail "transition-pair coverage:"; cat "$WORK/paircover.txt"
else
  npairs=$(wc -l < "$WORK/pairs.tsv" | tr -d ' ')
  pass "all $npairs distinct transition (from_phase, event) pairs consumed exactly once"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "OK  consumption-map complete: $(awk 'END {print NR-1}' "$MAP") rows, derived minimum $nreq covered"
  exit 0
else
  echo "NOK  $FAILED check group(s) failed"
  exit 1
fi
