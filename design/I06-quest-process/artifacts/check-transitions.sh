#!/usr/bin/env bash
# ============================================================================
# kquest I06 quest-process — check-transitions.sh (gate: transitions-check,
# AC2)
# ----------------------------------------------------------------------------
# Validates artifacts/transitions.tsv (paths relative to this script):
#   1. Structure: exact 6-column header; every row 6 fields; enum values for
#      from_phase / event / to_phase / phase_kind_exit; guard non-empty.
#   2. Priority order (P-PRIO): wildcard stop rows (any-*) precede all
#      explicit succession rows in file order.
#   3. Reachability: every phase kind (decompose, frontier-build, descent,
#      synthesis, verification) reachable from briefing-init; quest-done
#      reachable; no dead ends (every phase kind + briefing-init has an
#      outbound row; the terminal-by-law targets never appear as from_phase).
#   4. Guard resolution: every identifier in every guard resolves to an I01
#      law view (v_*), a config_key in stop-rules.tsv (dotted), a named
#      gate/metric in DESIGN.md's ```gates block, or a prior-law object
#      greppable in I01–I05. 'none' is legal.
#   5. The ruled three-zeros wiring: a decompose exit row requiring
#      v_decompose_remaining = 0, and closure rows sweeping
#      bare_claims / unreferenced / dual_arm_claims (I05 CONFIRMED).
#   6. Both exit disciplines wired: plateau-cut-backstop AND drained-exit
#      present in phase_kind_exit (plus mass-decay-primary).
#   7. Every evidence cell resolves: PoC absolute path (exists, §-anchor
#      text present in the file) or design-law (<name>) greppable in
#      I01–I05 artifacts.
# Exit 0 only on full success. macOS bash 3.2 safe.
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TSV="$SCRIPT_DIR/transitions.tsv"
STOP="$SCRIPT_DIR/stop-rules.tsv"
DESIGN="$SCRIPT_DIR/../DESIGN.md"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
POCROOT="/Users/eric/architect/spaces/20261110-knowledge-builder"
I01DESIGN="$ROOT/design/I01-core-model/DESIGN.md"
PRIOR_DIRS="$ROOT/design/I01-core-model $ROOT/design/I02-cross-quest $ROOT/design/I03-retrieval $ROOT/design/I04-agent-loop $ROOT/design/I05-tool-surface"
WORK="$(mktemp -d /tmp/kquest_i06_tr.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
fail() { echo "FAIL  $1"; FAILED=$((FAILED+1)); }
pass() { echo "pass  $1"; }

[ -f "$TSV" ] || { echo "FAIL  missing $TSV"; exit 1; }
[ -f "$STOP" ] || { echo "FAIL  missing $STOP (guard resolution needs its config keys)"; exit 1; }
[ -f "$DESIGN" ] || { echo "FAIL  missing $DESIGN"; exit 1; }
[ -f "$I01DESIGN" ] || { echo "FAIL  missing $I01DESIGN"; exit 1; }

FROM_ENUM="briefing-init decompose frontier-build descent synthesis verification any-phase any-work-phase any-finisher-phase"
EVENT_ENUM="phase_complete graph_invalid transcript_ceiling slow_stall_unattended retry_cap_exhausted budget_exhausted phase_cap verification_failed"
TO_ENUM="decompose frontier-build descent synthesis verification quest-done paused stopped"
EXIT_ENUM="autonomy-handoff counter-exit mass-floor-gate mass-decay-armed mass-decay-primary plateau-cut-backstop drained-exit descent-repeat citation-coverage-exit verification-terminal rework-pause route-to-synthesis pause-and-present stop-loud"
KINDS="decompose frontier-build descent synthesis verification"

echo "== 1. structure =="
head -n 1 "$TSV" > "$WORK/header"
if [ "$(cat "$WORK/header")" = "$(printf 'from_phase\tevent\tguard\tto_phase\tphase_kind_exit\tevidence')" ]; then
  pass "header is the exact 6-column law schema"
else
  fail "header mismatch: got '$(cat "$WORK/header")'"
fi
tail -n +2 "$TSV" > "$WORK/rows"
NROWS=$(wc -l < "$WORK/rows" | tr -d ' ')
[ "$NROWS" -gt 0 ] || fail "no data rows"
pass "$NROWS transition rows"

awk -F'\t' 'NF != 6 { print NR": "NF" fields" }' "$WORK/rows" > "$WORK/badwidth"
[ -s "$WORK/badwidth" ] && { fail "rows with wrong field count:"; sed 's/^/      /' "$WORK/badwidth"; } || pass "every row has 6 tab-separated fields"

cut -f1 "$WORK/rows" | sort -u > "$WORK/from_vals"
cut -f4 "$WORK/rows" | sort -u > "$WORK/to_vals"
cut -f2 "$WORK/rows" | sort -u > "$WORK/ev_vals"
cut -f5 "$WORK/rows" | sort -u > "$WORK/ex_vals"

for e in $FROM_ENUM; do echo "$e"; done > "$WORK/from_enum"
for e in $TO_ENUM; do echo "$e"; done > "$WORK/to_enum"
for e in $EVENT_ENUM; do echo "$e"; done > "$WORK/ev_enum"
for e in $EXIT_ENUM; do echo "$e"; done > "$WORK/ex_enum"

BADENUM=0
for val in $(cat "$WORK/from_vals"); do
  grep -qxF "$val" "$WORK/from_enum" || { fail "from_phase value '$val' not in enum"; BADENUM=1; }
done
for val in $(cat "$WORK/to_vals"); do
  grep -qxF "$val" "$WORK/to_enum" || { fail "to_phase value '$val' not in enum"; BADENUM=1; }
done
for val in $(cat "$WORK/ev_vals"); do
  grep -qxF "$val" "$WORK/ev_enum" || { fail "event value '$val' not in enum"; BADENUM=1; }
done
for val in $(cat "$WORK/ex_vals"); do
  grep -qxF "$val" "$WORK/ex_enum" || { fail "phase_kind_exit value '$val' not in enum"; BADENUM=1; }
done
[ "$BADENUM" -eq 0 ] && pass "from_phase/event/to_phase/phase_kind_exit values all in enum"

awk -F'\t' '$3 == "" { print NR": empty guard" }' "$WORK/rows" > "$WORK/badguard"
[ -s "$WORK/badguard" ] && { fail "empty guard cells:"; sed 's/^/      /' "$WORK/badguard"; } || pass "no empty guard cells"

echo "== 2. priority order (P-PRIO): stop rows precede succession rows =="
LASTANY=$(awk -F'\t' '$1 ~ /^any-/ { print NR }' "$WORK/rows" | tail -1)
FIRSTEXPLICIT=$(awk -F'\t' '$1 !~ /^any-/ { print NR }' "$WORK/rows" | head -1)
if [ -n "$LASTANY" ] && [ -n "$FIRSTEXPLICIT" ] && [ "$LASTANY" -lt "$FIRSTEXPLICIT" ]; then
  pass "wildcard stop rows (1..$LASTANY) precede explicit succession rows ($FIRSTEXPLICIT..$NROWS)"
else
  fail "priority order violated: last any-* row=$LASTANY, first explicit row=$FIRSTEXPLICIT (stop rows must come first)"
fi

echo "== 3. reachability from briefing-init + no dead ends =="
expand() { # from_phase value -> concrete set (space-separated)
  case "$1" in
    any-phase)          echo "briefing-init decompose frontier-build descent synthesis verification" ;;
    any-work-phase)     echo "decompose frontier-build descent" ;;
    any-finisher-phase) echo "synthesis verification" ;;
    *)                  echo "$1" ;;
  esac
}
# adjacency: only edges between phase-machine nodes count for reachability
: > "$WORK/edges"
awk -F'\t' '{ print $1 "\t" $4 }' "$WORK/rows" > "$WORK/rawedges"
while IFS=$'\t' read -r f t; do
  for src in $(expand "$f"); do
    case "$t" in
      briefing-init|decompose|frontier-build|descent|synthesis|verification)
        echo "$src $t" >> "$WORK/edges" ;;
    esac
  done
done < "$WORK/rawedges"
sort -u "$WORK/edges" -o "$WORK/edges"

# BFS from briefing-init
echo "briefing-init" > "$WORK/reached"
changed=1
while [ "$changed" -eq 1 ]; do
  changed=0
  while read -r s t; do
    if grep -qx "$s" "$WORK/reached" && ! grep -qx "$t" "$WORK/reached"; then
      echo "$t" >> "$WORK/reached"
      changed=1
    fi
  done < "$WORK/edges"
  sort -u "$WORK/reached" -o "$WORK/reached"
done
for k in $KINDS; do
  if grep -qx "$k" "$WORK/reached"; then pass "phase kind $k reachable from briefing-init"
  else fail "phase kind $k NOT reachable from briefing-init"; fi
done
if grep -qx "quest-done" <(cut -f4 "$WORK/rows" | sort -u); then
  pass "quest-done appears as a to_phase target (terminal)"
else
  fail "quest-done never targeted — the machine has no completion"
fi

# dead ends: every phase kind + briefing-init must have an outbound row
cut -f1 "$WORK/rows" | sort -u > "$WORK/froms"
for k in briefing-init $KINDS; do
  if grep -qx "$k" "$WORK/froms"; then pass "$k has outbound rows (no dead end)"
  else fail "$k has NO outbound row (dead end)"; fi
done
# terminal-by-law values must never be from_phase
for t in quest-done paused stopped; do
  if grep -qx "$t" "$WORK/from_vals"; then
    fail "$t appears as from_phase — it is terminal-by-law (I02 lifecycle owns its continuation)"
  else
    pass "$t never appears as from_phase (terminal-by-law)"
  fi
done

echo "== 4. guard resolution =="
# stop-rules config keys
tail -n +2 "$STOP" | cut -f8 | sort -u > "$WORK/config_keys"
# DESIGN gates-block names
awk '/^```gates[[:space:]]*$/ { inm=1; next }
     inm && /^```$/ { inm=0; next }
     inm && /^(gate|metric): / { split($0, a, "|"); split(a[1], b, ": ");
       gsub(/[[:space:]]/, "", b[2]); print b[2] }' "$DESIGN" | sort -u > "$WORK/gate_names"
NGATES=$(wc -l < "$WORK/gate_names" | tr -d ' ')
[ "$NGATES" -gt 0 ] && pass "DESIGN.md gates block defines $NGATES named gates/metrics" \
                  || fail "DESIGN.md has no (or empty) fenced 'gates' block"

KEYWORDS="AND OR NOT over none false true the all with when"
: > "$WORK/unresolved"
while IFS=$'\t' read -r f e g t x ev; do
  [ "$g" = "none" ] && continue
  for tok in $(echo "$g" | grep -oE '[A-Za-z_][A-Za-z0-9_.]*'); do
    echo "$KEYWORDS" | grep -qx "$tok" && continue
    case "$tok" in
      *.*)  echo "$tok" | grep -qxFf "$WORK/config_keys" || echo "row[$f/$e]: config key '$tok' not in stop-rules.tsv" >> "$WORK/unresolved" ;;
      v_*)  grep -q "$tok" "$I01DESIGN" || echo "row[$f/$e]: view '$tok' not found in I01 DESIGN.md" >> "$WORK/unresolved" ;;
      *)    if echo "$tok" | grep -qx "$WORK/gate_names" 2>/dev/null \
              || grep -qx "$tok" "$WORK/gate_names"; then :
           elif grep -rqF -- "$tok" $PRIOR_DIRS 2>/dev/null; then :
           else echo "row[$f/$e]: identifier '$tok' resolves nowhere (not a gates-block name, not prior-law)" >> "$WORK/unresolved"; fi ;;
    esac
  done
done < "$WORK/rows"
if [ -s "$WORK/unresolved" ]; then
  fail "unresolved guard identifiers:"; sed 's/^/      /' "$WORK/unresolved"
else
  pass "every guard identifier resolves (I01 view / stop-rules config key / gates block / prior-law)"
fi

echo "== 5. three-zeros wiring (CONFIRMED composition) =="
# 5a. decompose exit requires v_decompose_remaining = 0
if awk -F'\t' '$1 == "decompose" && $3 ~ /v_decompose_remaining = 0/ && $4 != "decompose"' "$WORK/rows" | grep -q .; then
  pass "decompose exit rows require v_decompose_remaining = 0"
else
  fail "no decompose exit row requires v_decompose_remaining = 0 (the ruled decompose zero is unwired)"
fi
# 5b. closure rows sweep the three zeros (bare/unreferenced/dual_arm)
if awk -F'\t' '$3 ~ /bare_claims/ && $3 ~ /unreferenced/ && $3 ~ /dual_arm_claims/' "$WORK/rows" | grep -q .; then
  NZ=$(awk -F'\t' '$3 ~ /bare_claims/ && $3 ~ /unreferenced/ && $3 ~ /dual_arm_claims/' "$WORK/rows" | wc -l | tr -d ' ')
  pass "$NZ transition rows sweep bare/unreferenced/dual_arm (the three-zeros closure verdict)"
else
  fail "no row sweeps bare_claims + unreferenced + dual_arm_claims (the CONFIRMED three-zeros wiring is absent)"
fi

echo "== 6. both exit disciplines wired =="
for need in mass-decay-primary plateau-cut-backstop drained-exit; do
  if grep -qxF "$need" "$WORK/ex_vals"; then
    pass "exit discipline '$need' wired in phase_kind_exit"
  else
    fail "exit discipline '$need' NOT wired (required: plateau-cut AND drained-exit, plus mass-decay primary)"
  fi
done

echo "== 7. evidence cells resolve =="
check_citations() { # $1 = file with one cell per line; $2 = label for messages
  local cell cit name path anchor
  : > "$WORK/cit_bad_$2"
  while IFS= read -r cell; do
    [ -n "$cell" ] || continue
    echo "$cell" | tr ';' '\n' | sed 's/^ *//; s/ *$//' | while IFS= read -r cit; do
      [ -n "$cit" ] || continue
      case "$cit" in
        "design-law (I0"[1-6]"/"*")")
          # judge-F2 fix: NAMESPACED citations design-law (I0N/<name>)
          # resolve <name> in THAT iteration's dir only — unambiguous across
          # the five DR numbering spaces (I06 = this artifact's own dir).
          qual=$(echo "$cit" | sed 's/^design-law *(//; s/).*$//')
          dirpart="${qual%%/*}"; namepart="${qual#*/}"
          case "$dirpart" in
            I01) nd="$ROOT/design/I01-core-model";;
            I02) nd="$ROOT/design/I02-cross-quest";;
            I03) nd="$ROOT/design/I03-retrieval";;
            I04) nd="$ROOT/design/I04-agent-loop";;
            I05) nd="$ROOT/design/I05-tool-surface";;
            I06) nd="$SCRIPT_DIR/..";;
          esac
          if grep -rqF -- "$namepart" "$nd" 2>/dev/null; then :; else
            echo "$2: namespaced design-law object '$namepart' not found in $dirpart" >> "$WORK/cit_bad_$2"; fi ;;
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
              # directory: check the anchor in any file under it
              grep -rqF -- "$anchor" "$path" 2>/dev/null || echo "$2: anchor '$anchor' not found under $(basename "$path")/" >> "$WORK/cit_bad_$2"
            fi
          fi ;;
        *) echo "$2: unrecognized citation '$cit'" >> "$WORK/cit_bad_$2" ;;
      esac
    done
  done < "$1"
}
cut -f6 "$WORK/rows" > "$WORK/ev_cells"
check_citations "$WORK/ev_cells" transitions
if [ -s "$WORK/cit_bad_transitions" ]; then
  fail "unresolved evidence citations:"; sort -u "$WORK/cit_bad_transitions" | sed 's/^/      /'
else
  pass "every evidence citation resolves (PoC path+§ anchor, or design-law object in I01–I05)"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "check-transitions: PASS ($NROWS rows)"
  exit 0
else
  echo "check-transitions: FAIL ($FAILED problems)"
  exit 1
fi
