#!/usr/bin/env bash
# ============================================================================
# kquest I06 quest-process — check-coverage.sh (gate: coverage-checks,
# AC1/AC3/AC4/AC6/AC7)
# ----------------------------------------------------------------------------
# Validates, against the files in this directory (paths relative to script):
#   1. Traceability (AC1): DESIGN.md's traceability table covers R-056..R-065
#      exactly once each, status DESIGNED or DEFERRED; a DEFERRED row names a
#      destination (ENTRY 7/8 or the implementation arc).
#   2. DECISIONS.md structure (AC6): DR-01.. sequential and unique; every
#      record has non-empty Decision / Rationale / Alternatives considered;
#      OPERATOR-RULING-NEEDED records carry Options + Recommendation; the six
#      REQUIRED records are present (exit discipline defaults, plateau window
#      + mass floor, MAX_PHASES + decompose-counts-toward-cap, briefing
#      autonomy threshold, re-synthesis model defaults, phase-cap vs
#      never-reportless interplay).
#   3. stop-rules.tsv (AC3): structure (8-column law schema, enums, sequential
#      unique rule ids, unique config keys); every provenance citation
#      resolves (PoC path + § anchor, or design-law object in I01–I05); every
#      provenance carries at least one PoC-path citation (a default anchored
#      in a PoC measurement, R-018); the UNMEASURED calibrations (frontier
#      floor, mass-decay cut, token/spend caps) are flagged by config key
#      inside an OPERATOR-RULING-NEEDED record in DECISIONS.md — never
#      invented as silent defaults.
#   4. Config-key parity (AC3): the set of namespace-qualified config keys
#      named in DESIGN.md + transitions.tsv equals the set of config_key
#      values in stop-rules.tsv — BOTH directions.
#   5. Prior-law immutability (AC7): design/I01-core-model/, I02-cross-quest/,
#      I03-retrieval/, I04-agent-loop/ AND I05-tool-surface/ are byte-identical
#      to their ratified (committed) state — git diff empty vs worktree HEAD,
#      no untracked additions, all tracked files present.
# Exit 0 only on full success. macOS bash 3.2 safe (perl used for token scan).
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESIGN="$SCRIPT_DIR/../DESIGN.md"
DECISIONS="$SCRIPT_DIR/../DECISIONS.md"
STOP="$SCRIPT_DIR/stop-rules.tsv"
TRANS="$SCRIPT_DIR/transitions.tsv"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
POCROOT="/Users/eric/architect/spaces/20261110-knowledge-builder"
PRIOR_DIRS="$ROOT/design/I01-core-model $ROOT/design/I02-cross-quest $ROOT/design/I03-retrieval $ROOT/design/I04-agent-loop $ROOT/design/I05-tool-surface"
WORK="$(mktemp -d /tmp/kquest_i06_cov.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
fail() { echo "FAIL  $1"; FAILED=$((FAILED+1)); }
pass() { echo "pass  $1"; }

for f in "$DESIGN" "$DECISIONS" "$STOP" "$TRANS"; do
  [ -f "$f" ] || { echo "FAIL  missing $f"; exit 1; }
done

echo "== 1. traceability: R-056..R-065 in DESIGN.md =="
i=56
while [ $i -le 65 ]; do
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
      if echo "$row" | grep -qE 'ENTRY [6-8]|implementation arc'; then
        pass "$rid DEFERRED -> $(echo "$row" | grep -oE 'ENTRY [6-8]|implementation arc' | head -1)"
      else
        fail "$rid DEFERRED but names no destination ENTRY 6..8 / implementation arc"
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
  for token in "exit discipline defaults" "plateau window" "MAX_PHASES" \
               "briefing autonomy" "re-synthesis model" "phase-cap"; do
    if grep -i -q -- "$token" "$WORK/headers"; then
      pass "required record present (header token '$token')"
    else
      fail "required record MISSING (no DR header matching '$token')"
    fi
  done
fi
echo "info  OPERATOR-RULING-NEEDED records: $(grep -c '\*\*Status:\*\* OPERATOR-RULING-NEEDED' "$DECISIONS")"

echo "== 3. stop-rules.tsv structure + provenance (AC3) =="
if [ "$(head -n 1 "$STOP")" = "$(printf 'rule_id\tscope\tmetric\tdefault\toperator\taction\tprovenance\tconfig_key')" ]; then
  pass "header is the exact 8-column law schema"
else
  fail "header mismatch: got '$(head -n 1 "$STOP")'"
fi
tail -n +2 "$STOP" > "$WORK/srows"
NSROWS=$(wc -l < "$WORK/srows" | tr -d ' ')
pass "$NSROWS stop-rule rows"
awk -F'\t' 'NF != 8 { print NR": "NF" fields" }' "$WORK/srows" > "$WORK/sbadwidth"
[ -s "$WORK/sbadwidth" ] && { fail "stop-rule rows with wrong field count:"; sed 's/^/      /' "$WORK/sbadwidth"; } || pass "every row has 8 tab-separated fields"

# enums + uniqueness + non-empty cells
sed 's/^SR-//; s/ .*//' "$WORK/srows" > "$WORK/snums" 2>/dev/null || true
cut -f1 "$WORK/srows" | sed 's/^SR-0*//; s/^0*//' | sort -n | awk 'BEGIN{i=0} {i++; if ($1 != i) { print "expected " i " got " $1; exit 1 }}' > "$WORK/sseq" || fail "rule_ids not sequential SR-01..SR-NN"
cmp -s /dev/null "$WORK/sseq" || true
if awk -F'\t' '{print $1}' "$WORK/srows" | sort | uniq -d | grep -q .; then
  fail "duplicate rule_id: $(awk -F'\t' '{print $1}' "$WORK/srows" | sort | uniq -d | tr '\n' ' ')"
else
  pass "rule_ids unique (SR-01..SR-$(printf '%02d' "$NSROWS"))"
fi
BADSCOPE=$(awk -F'\t' '$2 != "quest" && $2 != "phase" { print $1 }' "$WORK/srows" | tr '\n' ' ')
[ -n "$BADSCOPE" ] && fail "scope values outside {quest,phase}: $BADSCOPE" || pass "scope values all quest|phase"
BADOP=$(awk -F'\t' '$5 != ">" && $5 != ">=" && $5 != "<" && $5 != "<=" && $5 != "=" { print $1" op="$5 }' "$WORK/srows" | tr '\n' '; ')
[ -n "$BADOP" ] && fail "operator values outside the comparison enum: $BADOP" || pass "operator values all in {>,>=,<,<=,=}"
BADACT=$(awk -F'\t' '$6 != "route-to-synthesis" && $6 != "pause-and-present" && $6 != "stop-loud" && $6 != "adjust" { print $1" action="$6 }' "$WORK/srows" | tr '\n' '; ')
[ -n "$BADACT" ] && fail "action values outside the ruled enum: $BADACT" || pass "action values all in the ruled enum"
if cut -f8 "$WORK/srows" | sort | uniq -d | grep -q .; then
  fail "duplicate config_key: $(cut -f8 "$WORK/srows" | sort | uniq -d | tr '\n' ' ')"
else
  pass "config_keys unique ($NSROWS keys)"
fi
EMPTY=$(awk -F'\t' '$3 == "" || $4 == "" || $7 == "" || $8 == "" { print $1 }' "$WORK/srows" | tr '\n' ' ')
[ -n "$EMPTY" ] && fail "empty metric/default/provenance/config_key cells: $EMPTY" || pass "no empty metric/default/provenance/config_key cells"

# provenance resolution + the PoC-citation requirement
check_citations() { # $1 = file with one cell per line; $2 = label
  local cell cit name path anchor
  : > "$WORK/cit_bad_$2"
  while IFS= read -r cell; do
    [ -n "$cell" ] || continue
    echo "$cell" | tr ';' '\n' | sed 's/^ *//; s/ *$//' | while IFS= read -r cit; do
      [ -n "$cit" ] || continue
      case "$cit" in
        "design-law ("*")")
          name=$(echo "$cit" | sed 's/^design-law *(//; s/).*$//')
          if grep -rqF -- "$name" $PRIOR_DIRS 2>/dev/null; then :; else
            echo "$2: design-law object '$name' not greppable in I01-I05" >> "$WORK/cit_bad_$2"; fi ;;
        /*)
          case "$cit" in
            "$POCROOT"*) ;;
            *) echo "$2: PoC path outside the PoC root: $cit" >> "$WORK/cit_bad_$2"; continue ;;
          esac
          path=$(echo "$cit" | sed 's/ *§.*$//')
          anchor=$(echo "$cit" | sed -n 's/^.*§//p')
          if [ ! -e "$path" ]; then
            echo "$2: PoC path does not exist: $path" >> "$WORK/cit_bad_$2"; continue
          fi
          if [ -n "$anchor" ]; then
            if [ -f "$path" ]; then
              grep -qF -- "$anchor" "$path" || echo "$2: anchor '$anchor' not found in $(basename "$path")" >> "$WORK/cit_bad_$2"
            else
              grep -rqF -- "$anchor" "$path" 2>/dev/null || echo "$2: anchor '$anchor' not found under $(basename "$path")/" >> "$WORK/cit_bad_$2"
            fi
          fi ;;
        *) echo "$2: unrecognized citation '$cit'" >> "$WORK/cit_bad_$2" ;;
      esac
    done
  done < "$1"
}
cut -f7 "$WORK/srows" > "$WORK/prov_cells"
check_citations "$WORK/prov_cells" stoprules
if [ -s "$WORK/cit_bad_stoprules" ]; then
  fail "unresolved stop-rule provenance citations:"; sort -u "$WORK/cit_bad_stoprules" | sed 's/^/      /'
else
  pass "every stop-rule provenance citation resolves"
fi
NOPOC=$(awk -F'\t' '$7 !~ /^\/Users\/eric\/architect\/spaces\/20261110-knowledge-builder\// { print $1 }' "$WORK/srows" | tr '\n' ' ')
[ -n "$NOPOC" ] && fail "rows whose provenance carries NO PoC-path citation: $NOPOC" || pass "every default's provenance carries a PoC-path citation (R-018)"

echo "== 3b. unmeasured calibrations flagged in DECISIONS (AC3) =="
# These config keys ship backtest-anchored / measured-absence defaults and
# MUST appear inside an OPERATOR-RULING-NEEDED record in DECISIONS.md.
for key in quest.frontier_floor_mass descent.mass_decay_cut_fraction quest.token_budget quest.spend_budget_usd; do
  found=0
  k=1
  while [ $k -le "$nrec" ]; do
    blk="$WORK/blk_$(printf '%02d' $k)"
    if grep -qF "$key" "$blk" && grep -q '^\*\*Status:\*\* OPERATOR-RULING-NEEDED' "$blk"; then
      found=1; pass "$key flagged OPERATOR-RULING-NEEDED (DR-$(printf '%02d' $k))"; break
    fi
    k=$((k+1))
  done
  [ "$found" -eq 0 ] && fail "$key (unmeasured calibration) is NOT flagged in any OPERATOR-RULING-NEEDED record"
done

echo "== 4. config-key parity: DESIGN+transitions vs stop-rules (AC3) =="
cut -f8 "$WORK/srows" | sort -u > "$WORK/keys_stop"
perl -ne 'while (/(?<![\/\w-])(?:quest|phase|descent|engine|synthesis|verification|session|frontier_build|decompose)\.[a-z][a-z0-9_]*/g) { print "$&\n" }' \
  "$DESIGN" "$TRANS" | sort -u > "$WORK/keys_docs"
ONLY_STOP=$(comm -23 "$WORK/keys_stop" "$WORK/keys_docs" | tr '\n' ' ')
ONLY_DOCS=$(comm -13 "$WORK/keys_stop" "$WORK/keys_docs" | tr '\n' ' ')
[ -n "$ONLY_STOP" ] && fail "config keys in stop-rules.tsv never named in DESIGN/transitions: $ONLY_STOP"
[ -n "$ONLY_DOCS" ] && fail "config keys named in DESIGN/transitions missing from stop-rules.tsv: $ONLY_DOCS"
if [ -z "$ONLY_STOP" ] && [ -z "$ONLY_DOCS" ]; then
  pass "config-key parity 1:1 both directions ($(wc -l < "$WORK/keys_stop" | tr -d ' ') keys)"
fi

echo "== 5. prior-law immutability (AC7: I01+I02+I03+I04+I05 byte-identical) =="
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  fail "worktree is not a git repository — cannot verify prior-law immutability"
else
  head_sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)
  echo "info  worktree HEAD: $head_sha"
  ok_all=1
  for dir in design/I01-core-model design/I02-cross-quest design/I03-retrieval design/I04-agent-loop design/I05-tool-surface; do
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
