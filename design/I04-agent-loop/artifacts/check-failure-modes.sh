#!/usr/bin/env bash
# ============================================================================
# kquest I04 agent-loop — check-failure-modes.sh (gate: failure-modes-parse,
# AC2/AC3)
# ----------------------------------------------------------------------------
# Parses artifacts/failure-modes.tsv (THE handling table, R-045) and fails
# unless ALL of the following hold:
#   1. Structure: the exact 7-column header; every data row has exactly 7
#      TAB-separated fields; no empty cell anywhere; at least 12 data rows.
#   2. Ids: FM-01..FM-NN unique and sequential (zero-padded, no gaps).
#   3. Classes: every `class` cell is in the enum
#      retryable | terminal | wedge-guard | budget-guard.
#   4. Evidence (AC3): every `evidence` cell is "<path> §<literal section
#      substring>"; the path resolves (absolute, worktree-relative, or
#      space-root-relative — the PoC notes and the fast-llm gem live outside
#      this repo worktree), AND the literal substring actually appears in the
#      cited file. A broken or unresolvable citation fails the gate.
#   5. Minimum-law coverage (R-038–R-046 implied failure modes): each of
#      empty-completion, seed-0, transcript ceiling, wedge, timeout, dialect
#      mismatch, provider 429, provider 5xx, malformed tool call, stream
#      truncation, one-writer violation, budget ceiling appears in the table.
# Exit 0 only on full success. macOS bash 3.2 safe.
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TSV="$SCRIPT_DIR/failure-modes.tsv"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"           # the repo worktree root

# Space-root discovery: walk up from the worktree root until a directory
# containing architecture/BRIEF.md is found (the space root holds
# architecture/, repos/, notes/). Gem and BRIEF citations are space-relative;
# PoC citations are absolute; prior-law citations are worktree-relative.
SPACE_ROOT=""
d="$ROOT"
i=0
while [ $i -lt 8 ]; do
  if [ -f "$d/architecture/BRIEF.md" ]; then SPACE_ROOT="$d"; break; fi
  d="$(dirname "$d")"
  i=$((i+1))
done

FAILED=0
fail() { echo "FAIL  $1"; FAILED=$((FAILED+1)); }
pass() { echo "pass  $1"; }

[ -f "$TSV" ] || { echo "FAIL  missing $TSV"; exit 1; }

echo "info  worktree root: $ROOT"
[ -n "$SPACE_ROOT" ] && echo "info  space root:   $SPACE_ROOT" \
                     || echo "info  space root:   NOT FOUND (space-relative citations will fail)"

# resolve_path <p>: echo the first existing form, or empty.
resolve_path() {
  p="$1"
  case "$p" in
    /*) [ -e "$p" ] && { echo "$p"; return; } ; return ;;
  esac
  [ -e "$ROOT/$p" ] && { echo "$ROOT/$p"; return; }
  if [ -n "$SPACE_ROOT" ] && [ -e "$SPACE_ROOT/$p" ]; then echo "$SPACE_ROOT/$p"; return; fi
  return
}

echo "== 1. TSV structure =="
HEADER_WANT="$(printf 'id\tsignature\tclass\trequired_behavior\tmax_retries_or_bound\tevidence\tdestination')"
HEADER_GOT="$(head -1 "$TSV")"
if [ "$HEADER_GOT" = "$HEADER_WANT" ]; then
  pass "header exact (7 named columns)"
else
  fail "header mismatch: got '$HEADER_GOT'"
fi

bad_nf=$(awk -F'\t' 'NR>1 && NF!=7 {print NR}' "$TSV" | tr '\n' ' ')
[ -n "$bad_nf" ] && fail "rows with field count != 7 (TAB-separated): line(s) $bad_nf" \
                 || pass "every data row has exactly 7 TAB-separated fields"

empty_cells=$(awk -F'\t' 'NR>1 { for (i=1;i<=NF;i++) if ($i ~ /^[[:space:]]*$/) { print NR " col" i } }' "$TSV")
[ -n "$empty_cells" ] && fail "empty cells: $(echo "$empty_cells" | tr '\n' '; ')" \
                       || pass "no empty cells"

nrows=$(awk 'NR>1' "$TSV" | wc -l | tr -d ' ')
if [ "$nrows" -ge 12 ]; then
  pass "$nrows failure modes (>= 12)"
else
  fail "only $nrows failure modes (< 12)"
fi

echo "== 2. ids unique + sequential =="
awk -F'\t' 'NR>1 {print $1}' "$TSV" > /tmp/kquest_i04_ids.$$
n=$(wc -l < /tmp/kquest_i04_ids.$$ | tr -d ' ')
dupes=$(sort /tmp/kquest_i04_ids.$$ | uniq -d | tr '\n' ' ')
k=1; seqok=1
while [ $k -le "$n" ]; do
  want=$(printf 'FM-%02d' $k)
  got=$(sed -n "${k}p" /tmp/kquest_i04_ids.$$)
  [ "$got" = "$want" ] || { seqok=0; fail "row $k id is '$got' (expected $want)"; }
  k=$((k+1))
done
[ $seqok -eq 1 ] && pass "ids FM-01..FM-$(printf '%02d' "$n") sequential"
[ -n "$dupes" ] && fail "duplicate ids: $dupes"
rm -f /tmp/kquest_i04_ids.$$

echo "== 3. class enum =="
badclass=$(awk -F'\t' 'NR>1 && $3 !~ /^(retryable|terminal|wedge-guard|budget-guard)$/ {print NR": "$3}' "$TSV")
[ -n "$badclass" ] && fail "class cells outside the enum: $(echo "$badclass" | tr '\n' '; ')" \
                    || pass "every class in {retryable, terminal, wedge-guard, budget-guard}"

echo "== 4. evidence citations resolve (AC3) =="
awk -F'\t' 'NR>1 {print $1 "\t" $6}' "$TSV" > /tmp/kquest_i04_evid.$$
while IFS="$(printf '\t')" read -r id evid; do
  p="${evid%% §*}"
  rest="${evid#* §}"
  if [ "$rest" = "$evid" ]; then
    sec=""
  else
    sec="$rest"
  fi
  if [ -z "$p" ]; then
    fail "$id: evidence cell has no path"
    continue
  fi
  resolved="$(resolve_path "$p")"
  if [ -z "$resolved" ]; then
    fail "$id: evidence path does not resolve: $p"
    continue
  fi
  if [ -n "$sec" ]; then
    if grep -qF -- "$sec" "$resolved" 2>/dev/null; then
      pass "$id: $p §'${sec}'"
    else
      fail "$id: section marker '${sec}' not found in $p"
    fi
  else
    fail "$id: evidence cell lacks a ' §<section>' marker"
  fi
done < /tmp/kquest_i04_evid.$$
rm -f /tmp/kquest_i04_evid.$$

echo "== 5. minimum-law coverage =="
# law-name<TAB>token — the token must appear literally somewhere in the TSV.
MIN_LAWS="empty-completion<TAB>empty completion
seed-0<TAB>seed-0
transcript ceiling<TAB>ceiling
wedge<TAB>wedge
timeout<TAB>TimeoutError
dialect mismatch<TAB>dialect
provider 429<TAB>429
provider 5xx<TAB>5xx
malformed tool call<TAB>unparseable
stream truncation<TAB>finish_reason
one-writer violation<TAB>one-writer
budget ceiling<TAB>budget ceiling"
echo "$MIN_LAWS" | sed "s/<TAB>/$(printf '\t')/g" > /tmp/kquest_i04_laws.$$
while IFS="$(printf '\t')" read -r law token; do
  [ -z "$law" ] && continue
  if grep -qF -- "$token" "$TSV"; then
    pass "minimum law '$law' covered (token '$token')"
  else
    fail "minimum law '$law' NOT covered (token '$token' absent from the table)"
  fi
done < /tmp/kquest_i04_laws.$$
rm -f /tmp/kquest_i04_laws.$$

if [ "$FAILED" -eq 0 ]; then
  echo "check-failure-modes: PASS ($nrows failure modes)"
  exit 0
else
  echo "check-failure-modes: FAIL ($FAILED problems)"
  exit 1
fi
