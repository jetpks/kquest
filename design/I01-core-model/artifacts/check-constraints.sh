#!/usr/bin/env bash
# ============================================================================
# kquest I01 core-model — check-constraints.sh (gate: constraints-bite, AC4)
# ----------------------------------------------------------------------------
# Applies schema+seed to a scratch database, then runs a battery of negative
# probes. Each probe is a statement that VIOLATES a schema-expressible law
# and MUST be refused by a specific CHECK / FK / UNIQUE constraint; the
# probe passes only when psql exits nonzero AND the expected constraint name
# appears in the error. A positive control insert proves the battery is not
# "passing" due to a broken connection. Exit 0 only if the control succeeds
# and every probe is refused by its named constraint.
#
# Laws that are NOT schema-expressible (cross-table: closure satisfy_one,
# terminal XOR derives_from, evidence edge_min, conflicts >= 2 floor,
# one-active-writer-per-quest) are cataloged in DESIGN.md §5 with their
# tool-time / phase-gate enforcement points and are intentionally absent
# from this battery (see the Builder Report's "not schema-expressible" list).
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB="kquest_i01_check"

if command -v psql >/dev/null 2>&1; then
  PSQL="psql"
else
  PSQL="/opt/homebrew/bin/psql"
fi

ALICE='00000000-0000-4000-8000-000000000001'
BOB='00000000-0000-4000-8000-000000000002'
QA='b0000000-0000-4000-8000-000000000001'
QB='b0000000-0000-4000-8000-000000000002'
QC='b0000000-0000-4000-8000-000000000003'
S1='a0000000-0000-4000-8000-000000000001'   # citable, alice
S2='a0000000-0000-4000-8000-000000000002'   # citable, alice
S5='a0000000-0000-4000-8000-000000000005'   # AGENDA, alice
S6='a0000000-0000-4000-8000-000000000006'   # citable, bob
K1='f0000000-0000-4000-8000-000000000001'   # terminal definitional-mathematical, QA
K4='f0000000-0000-4000-8000-000000000004'   # derived claim, QA
K5='f0000000-0000-4000-8000-000000000005'   # derived claim, QA
K6='f0000000-0000-4000-8000-000000000006'   # bare + open frontier, QA
G1='f0000000-0000-4000-8000-000000000011'   # quest-B graft claim
E1='10000000-0000-4000-8000-000000000001'
SA='e0000000-0000-4000-8000-000000000001'   # session, quest A
SB='e0000000-0000-4000-8000-000000000002'   # session, quest C (tenant B)
PQA1='d0000000-0000-4000-8000-000000000001' # phase, quest A
PQC1='d0000000-0000-4000-8000-000000000003' # phase, quest C

FAILED=0
PASSED=0

"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1
"$PSQL" -q -d postgres -c "CREATE DATABASE $DB" >/dev/null 2>&1 || { echo "FAIL: create db"; exit 1; }
"$PSQL" -q -d "$DB" -c "CREATE EXTENSION vector" >/dev/null 2>&1 \
  || { echo "FAIL: CREATE EXTENSION vector"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$SCRIPT_DIR/schema.sql" >/dev/null 2>&1 \
  || { echo "FAIL: schema.sql"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$SCRIPT_DIR/seed.sql" >/dev/null 2>&1 \
  || { echo "FAIL: seed.sql"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }

echo "== positive control: a legal claim MUST be accepted =="
if out=$("$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" <<SQL
INSERT INTO claims (user_id, quest_id, quest_seq, text, urn)
VALUES ('$BOB', '$QC', 1, 'Control claim accepted by the schema battery.', 'kb:claim:1111111111');
SQL
); then
  echo "pass  control — legal insert accepted"
  PASSED=$((PASSED+1))
else
  echo "FAIL  control — legal insert refused (environment or schema broken):"
  echo "$out" | sed 's/^/      /'
  FAILED=$((FAILED+1))
fi

probe() {
  name="$1"; expect="$2"; sql="$3"
  out="$("$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" 2>&1 <<< "$sql")"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL  $name — ACCEPTED (expected refusal by $expect)"
    FAILED=$((FAILED+1))
  elif echo "$out" | grep -q "$expect"; then
    echo "pass  $name — refused by $expect"
    PASSED=$((PASSED+1))
  else
    echo "FAIL  $name — refused, but not by $expect:"
    echo "$out" | sed 's/^/      /' | head -3
    FAILED=$((FAILED+1))
  fi
}

echo "== negative probes (each must be refused by its named constraint) =="

probe "C01 duplicate canonical claim text per quest (L5 dedup guard, PoC unique_per_label)" \
  "uq_claims_quest_canonical" \
  "INSERT INTO claims (user_id, quest_id, quest_seq, text, urn)
   VALUES ('$ALICE', '$QA', 9, 'Momentum profits   persist after controlling for market beta in the fixture literature.', 'kb:claim:2222222222');"

probe "C02 agenda source cited by evidence (R-003 anchorable-only)" \
  "fk_evidence_source" \
  "INSERT INTO evidence (user_id, quest_id, source_id, source_anchorable, snapshot_char_count, span_start, span_end, span_text, reading)
   VALUES ('$ALICE', '$QA', '$S5', true, 214, 0, 9, 'This agen', 'agenda source must never anchor');"

probe "C03 evidence span beyond snapshot size (L1 offsets bound)" \
  "ck_evidence_span_bounded" \
  "INSERT INTO evidence (user_id, quest_id, source_id, source_anchorable, snapshot_char_count, span_start, span_end, span_text, reading)
   VALUES ('$ALICE', '$QA', '$S1', true, 10, 0, 24, 'The t-statistic is the', 'span claims 24 chars but snapshot pinned at 10');"

probe "C04 span_text length incoherent with offsets (L1)" \
  "ck_evidence_span_len" \
  "INSERT INTO evidence (user_id, quest_id, source_id, source_anchorable, snapshot_char_count, span_start, span_end, span_text, reading)
   VALUES ('$ALICE', '$QA', '$S1', true, 400, 0, 5, 'The t-statistic is the ratio', 'length must equal span_end - span_start');"

probe "C05 frontier uncertainty out of range (L4, PoC range 1..5)" \
  "ck_frontier_uncertainty" \
  "INSERT INTO frontier_entries (user_id, quest_id, claim_id, need, uncertainty, relevance, spawned_by_phase_id)
   VALUES ('$ALICE', '$QA', '$K6', 'a brand new need string for the range probe', 6, 4, '$PQA1');"

probe "C06 duplicate frontier need per quest (distinct-needs law)" \
  "uq_frontier_need" \
  "INSERT INTO frontier_entries (user_id, quest_id, claim_id, need, uncertainty, relevance, spawned_by_phase_id)
   VALUES ('$ALICE', '$QA', '$K5', 'primary empirical evidence on momentum crash frequency and depth by regime', 2, 2, '$PQA1');"

probe "C07 second OPEN frontier entry for same claim (PoC class-f re-add)" \
  "uq_frontier_open_per_claim" \
  "INSERT INTO frontier_entries (user_id, quest_id, claim_id, need, uncertainty, relevance, spawned_by_phase_id)
   VALUES ('$ALICE', '$QA', '$K6', 'another distinct need for the same open claim', 2, 2, '$PQA1');"

probe "C08 frontier closed without closure_type (closure pairing law)" \
  "ck_frontier_closure_pair" \
  "UPDATE frontier_entries SET state = 'closed', closed_at = now() WHERE need LIKE 'cross-market%';"

probe "C09 evidence edge to claim of another quest (D3 hermetic graphs)" \
  "fk_evidence_edges_claim" \
  "INSERT INTO evidence_edges (user_id, quest_id, evidence_id, relation, claim_id, position)
   VALUES ('$ALICE', '$QA', '$E1', 'supports', '$G1', 5);"

probe "C10 derivation parent from another quest (D3)" \
  "fk_claim_derivations_parent" \
  "INSERT INTO claim_derivations (user_id, quest_id, claim_id, parent_claim_id, position)
   VALUES ('$ALICE', '$QA', '$K5', '$G1', 2);"

probe "C11 derivation position collision (R-008 ordered edges)" \
  "uq_claim_derivations_positions" \
  "INSERT INTO claim_derivations (user_id, quest_id, claim_id, parent_claim_id, position)
   VALUES ('$ALICE', '$QA', '$K4', '$K1', 1);"

probe "C12 terminal with empty basis (L2 basis required with type)" \
  "ck_claims_terminal_basis_nonempty" \
  "INSERT INTO claims (user_id, quest_id, quest_seq, text, terminal_type, terminal_basis, urn)
   VALUES ('$ALICE', '$QA', 10, 'A claim with a blank terminal basis.', 'primary-empirical', '   ', 'kb:claim:3333333333');"

probe "C13 invalid terminal_type value (L2 typed terminals)" \
  "ck_claims_terminal_type" \
  "INSERT INTO claims (user_id, quest_id, quest_seq, text, terminal_type, terminal_basis, urn)
   VALUES ('$ALICE', '$QA', 11, 'A claim with an untyped terminal.', 'mathematical', 'made up', 'kb:claim:4444444444');"

probe "C14 cross-tenant evidence (alice citing bob's source, R-001/D6)" \
  "fk_evidence_source" \
  "INSERT INTO evidence (user_id, quest_id, source_id, source_anchorable, snapshot_char_count, span_start, span_end, span_text, reading)
   VALUES ('$ALICE', '$QA', '$S6', true, 300, 0, 9, 'The fixtu', 'cross-tenant citation');"

probe "C15 tool_call wired to session of another quest (L8 chain)" \
  "fk_tool_calls_session" \
  "INSERT INTO tool_calls (user_id, quest_id, session_id, seq, tool, args, result, ok)
   VALUES ('$BOB', '$QC', '$SA', 9, 'graph', '{}', '{}', true);"

probe "C16 usage row with negative input tokens (D10 ledger)" \
  "ck_usage_input" \
  "INSERT INTO usage_events (user_id, quest_id, phase_id, session_id, kind, model, input_tokens, output_tokens)
   VALUES ('$BOB', '$QC', '$PQC1', '$SB', 'llm', 'qwen3.8-flash-next', -5, 10);"

probe "C17 chunk offset beyond snapshot size (L1 offsets law)" \
  "ck_chunks_span_bounded" \
  "INSERT INTO chunks (source_id, user_id, strategy_id, ordinal, text, char_start, char_end, snapshot_char_count, source_anchorable)
   VALUES ('$S1', '$ALICE', 'c0000000-0000-4000-8000-000000000001', 99, 'xxxxx', 0, 5, 1, true);"

probe "C18 invalid phase kind (R-012 phase set)" \
  "ck_phases_kind" \
  "INSERT INTO phases (user_id, quest_id, kind)
   VALUES ('$ALICE', '$QA', 'mining');"

probe "C19 source URN not in kb:src:base58 format (DR-02)" \
  "ck_sources_urn_format" \
  "INSERT INTO sources (user_id, url, canonical_url, urn, title, role, fetched_at, snapshot_sha256, raw_sha256, snapshot_char_count)
   VALUES ('$ALICE', 'https://fixture.example/x', 'https://fixture.example/x', 'kb:src:0OIl1l!!', 'Bad urn', 'citable', now(),
           repeat('a', 64), repeat('b', 64), 100);"

probe "C20 duplicate claim quest_seq (K-alias collision)" \
  "uq_claims_quest_seq" \
  "INSERT INTO claims (user_id, quest_id, quest_seq, text, urn)
   VALUES ('$ALICE', '$QA', 1, 'A distinct canonical text with a colliding alias.', 'kb:claim:5555555555');"

probe "C21 duplicate evidence span in one quest (PoC duplicate-span refusal)" \
  "uq_evidence_quest_span" \
  "INSERT INTO evidence (user_id, quest_id, source_id, source_anchorable, snapshot_char_count, span_start, span_end, span_text, reading)
   SELECT user_id, quest_id, source_id, source_anchorable, snapshot_char_count, span_start, span_end, span_text,
          'same span must attach edges, not clone evidence'
   FROM evidence WHERE id = '$E1';"

probe "C22 usage session/phase mismatch (D10 chain coherence)" \
  "fk_usage_session" \
  "INSERT INTO usage_events (user_id, quest_id, phase_id, session_id, kind, model, input_tokens, output_tokens)
   VALUES ('$BOB', '$QC', '$PQC1', '$SA', 'llm', 'glm-5.3', 10, 10);"

probe "C23 derivation self-loop (claim derives from itself)" \
  "ck_claim_derivations_no_self" \
  "INSERT INTO claim_derivations (user_id, quest_id, claim_id, parent_claim_id, position)
   VALUES ('$ALICE', '$QA', '$K4', '$K4', 9);"

probe "C24 conflict citing an agenda source (R-003 never citable)" \
  "fk_conflict_sources_source" \
  "INSERT INTO conflict_sources (conflict_id, source_id, user_id, source_anchorable)
   VALUES ('50000000-0000-4000-8000-000000000001', '$S5', '$ALICE', true);"

probe "C25 whitespace-only claim text (PoC nonempty law)" \
  "ck_claims_text_nonempty" \
  "INSERT INTO claims (user_id, quest_id, quest_seq, text, urn)
   VALUES ('$ALICE', '$QA', 12, '    ', 'kb:claim:6666666666');"

probe "C26 evidence with empty reading (R-007 reading required)" \
  "ck_evidence_reading_nonempty" \
  "INSERT INTO evidence (user_id, quest_id, source_id, source_anchorable, snapshot_char_count, span_start, span_end, span_text, reading)
   VALUES ('$ALICE', '$QA', '$S2', true, 500, 0, 4, 'In t', '   ');"

probe "C27 tool_call ok=true with error_class set (L8 shape)" \
  "ck_tool_calls_error_shape" \
  "INSERT INTO tool_calls (user_id, quest_id, session_id, seq, tool, args, result, ok, error_class)
   VALUES ('$ALICE', '$QA', '$SA', 9, 'graph', '{}', '{}', true, 'GRAPH_INVALID');"

probe "C28 invalid session mode (L13)" \
  "ck_sessions_mode" \
  "INSERT INTO sessions (user_id, quest_id, phase_id, mode, driver, model)
   VALUES ('$ALICE', '$QA', '$PQA1', 'semiautonomous', 'orchestrator', 'glm-5.3');"

probe "C29 quest provenance fresh but source_quest_id set (R-011 pairing)" \
  "ck_quests_provenance_pair" \
  "INSERT INTO quests (user_id, topic, provenance_kind, source_quest_id, web_call_budget, token_budget, spend_budget_usd)
   VALUES ('$ALICE', 'Bad provenance quest', 'fresh', '$QB', 10, 1000, 1.0);"

probe "C30 source with empty title (R-002 title required)" \
  "ck_sources_title_nonempty" \
  "INSERT INTO sources (user_id, url, canonical_url, urn, title, role, fetched_at, snapshot_sha256, raw_sha256, snapshot_char_count)
   VALUES ('$ALICE', 'https://fixture.example/y', 'https://fixture.example/y', 'kb:src:7777777777', '  ', 'citable', now(),
           repeat('a', 64), repeat('b', 64), 100);"

echo "== summary: $PASSED passed, $FAILED failed =="

echo "== dropping scratch database $DB =="
"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1

if [ "$FAILED" -eq 0 ]; then
  echo "check-constraints: PASS"
  exit 0
else
  echo "check-constraints: FAIL"
  exit 1
fi
