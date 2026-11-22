#!/usr/bin/env bash
# ============================================================================
# kquest I02 cross-quest — check-constraints.sh (gate: constraints-bite, AC4)
# ----------------------------------------------------------------------------
# Applies I01 schema+seed then schema-i02+seed-i02 to a scratch database and
# runs negative probes of the NEW laws. Each probe VIOLATES a schema-
# expressible law and MUST be refused by a specific named CHECK / FK /
# UNIQUE constraint; a probe passes only when psql exits nonzero AND the
# expected constraint name appears in the error. A positive control insert
# proves the battery is live. Exit 0 only if the control succeeds and every
# probe is refused by its named constraint.
#
# NEW LAWS THAT ARE NOT SCHEMA-EXPRESSIBLE (cross-table or workflow), with
# their named enforcement points (DESIGN.md §10 constraint catalog):
#   N1 graph mutation of a complete/archived quest's rows is refused
#      -> tool-time precondition in the graph ops layer (ENTRY 5, R-047):
#         refuse unless quests.state IN ('active','paused'); archive op
#      (ENTRY 6, R-056) re-checks; drift is sweep-detectable forever via the
#      pinned counts_at_archive (queries-i02.sql X1_archive_drift).
#   N2 match_kind='exact' pairs must hold byte-equal canonical texts
#      -> merge ops layer at proposal time (ENTRY 5); seed self-verifies.
#   N3 terminal agreement among members at approval (DR-06 ruling)
#      -> merge approval op (ENTRY 5/6); catalog row.
#   N4 citations-exist iff bound (cross-table half of the binding pairing)
#      -> binding pass refuses dual writes (ENTRY 5, R-053); sweep at
#      finalization.
#   N5 body_sha256 equals the blob bytes -> storage seam (ENTRY 5), same
#      class as I01's L1 byte-proof.
#   N6 standing flip + unflip atomicity, and standing only on BOUND versions
#      -> finalization op transaction (ENTRY 5, R-053).
#   N7 one-active-writer / pause / cold-boot (I01 DR-12) -> ENTRY 4.
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
I01_DIR="$SCRIPT_DIR/../../I01-core-model/artifacts"
DB="kquest_i02_probe"

if command -v psql >/dev/null 2>&1; then
  PSQL="psql"
else
  PSQL="/opt/homebrew/bin/psql"
fi

ALICE='00000000-0000-4000-8000-000000000001'
BOB='00000000-0000-4000-8000-000000000002'
QA='b0000000-0000-4000-8000-000000000001'
QC='b0000000-0000-4000-8000-000000000003'
QD='b0000000-0000-4000-8000-000000000010'
S1='a0000000-0000-4000-8000-000000000001'   # citable, alice
S2='a0000000-0000-4000-8000-000000000002'   # citable, alice
S5='a0000000-0000-4000-8000-000000000005'   # AGENDA, alice
S7='a0000000-0000-4000-8000-000000000007'   # citable, alice (late fetch)
K4='f0000000-0000-4000-8000-000000000004'   # quest A claim (E1 approved)
K5='f0000000-0000-4000-8000-000000000005'   # quest A claim (E4 reversed)
K7='f0000000-0000-4000-8000-000000000007'   # quest A claim, untouched
GK='f0000000-0000-4000-8000-000000000003'   # quest A terminal claim
K11='f0000000-0000-4000-8000-000000000011'  # quest B graft claim (E2 proposed)
D1='f0000000-0000-4000-8000-000000000101'   # quest D graft claim (E3 candidate)
CC1='80000000-0000-4000-8000-000000000001'  # canonical, alice (E1 member k4)
CC2='80000000-0000-4000-8000-000000000002'  # canonical, alice (reversal fixture)
RV1='aa000000-0000-4000-8000-0000000000b1'  # report v1 (stale, unbound)
RV2='aa000000-0000-4000-8000-0000000000b2'  # report v2 (standing, bound)
PD11='d0000000-0000-4000-8000-000000000011' # quest D decompose phase
PD16='d0000000-0000-4000-8000-000000000016' # quest D verification r2 (complete)
WS1='cc000000-0000-4000-8000-000000000001'  # workspace kquest-lab
SA='e0000000-0000-4000-8000-000000000001'   # session, quest A

FAILED=0
PASSED=0

"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1
"$PSQL" -q -d postgres -c "CREATE DATABASE $DB" >/dev/null 2>&1 || { echo "FAIL: create db"; exit 1; }
"$PSQL" -q -d "$DB" -c "CREATE EXTENSION vector" >/dev/null 2>&1 \
  || { echo "FAIL: CREATE EXTENSION vector"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I01_DIR/schema.sql" >/dev/null 2>&1 \
  || { echo "FAIL: I01 schema.sql"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I01_DIR/seed.sql" >/dev/null 2>&1 \
  || { echo "FAIL: I01 seed.sql"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$SCRIPT_DIR/schema-i02.sql" >/dev/null 2>&1 \
  || { echo "FAIL: schema-i02.sql"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$SCRIPT_DIR/seed-i02.sql" >/dev/null 2>&1 \
  || { echo "FAIL: seed-i02.sql"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }

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

echo "== positive control: a legal merge candidate MUST be accepted =="
if out=$("$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" <<SQL
INSERT INTO canonical_claims (id, user_id, canonical_text, urn)
VALUES ('80000000-0000-4000-8000-000000000099', '$ALICE',
        'Control canonical claim accepted by the schema battery.',
        'kb:cclaim:9999999992');
INSERT INTO merge_events (user_id, canonical_claim_id, quest_id, quest_claim_id,
                          match_kind, state, justification)
VALUES ('$ALICE', '80000000-0000-4000-8000-000000000099', '$QA', '$K7',
        'exact', 'candidate', 'control row: untouched quest-A claim');
SQL
); then
  echo "pass  control — legal canonical claim + candidate accepted"
  PASSED=$((PASSED+1))
else
  echo "FAIL  control — legal insert refused (environment or schema broken):"
  echo "$out" | sed 's/^/      /'
  FAILED=$((FAILED+1))
fi

echo "== negative probes (each must be refused by its named constraint) =="

# ---- merge events: propose-only, audit, slot pairing, one-active ----
probe "X01 approved merge without decided_by (propose-only law)" \
  "ck_merge_events_decision_pair" \
  "INSERT INTO merge_events (user_id, canonical_claim_id, quest_id, quest_claim_id, match_kind, state, justification)
   VALUES ('$ALICE', '$CC1', '$QA', '$K7', 'exact', 'approved', 'approved without a recorded decision');"

probe "X02 candidate with decided_by set (undecided states carry no decision)" \
  "ck_merge_events_decision_pair" \
  "INSERT INTO merge_events (user_id, canonical_claim_id, quest_id, quest_claim_id, match_kind, state, justification, decided_by, decided_at)
   VALUES ('$ALICE', '$CC1', '$QA', '$K7', 'exact', 'candidate', 'candidate carries a decision', '$ALICE', now());"

probe "X03 near_dup merge without similarity score (designated slot pairing)" \
  "ck_merge_events_similarity_pair" \
  "INSERT INTO merge_events (user_id, canonical_claim_id, quest_id, quest_claim_id, match_kind, state, justification)
   VALUES ('$ALICE', '$CC2', '$QA', '$K7', 'near_dup', 'candidate', 'near-dup without a score');"

probe "X04 exact merge with a similarity score (exact is score-free)" \
  "ck_merge_events_similarity_pair" \
  "INSERT INTO merge_events (user_id, canonical_claim_id, quest_id, quest_claim_id, match_kind, similarity, state, justification)
   VALUES ('$ALICE', '$CC1', '$QA', '$K7', 'exact', 0.9100, 'candidate', 'exact with a score');"

probe "X05 reversed merge without reversed_by (reversal audit law)" \
  "ck_merge_events_reversal_pair" \
  "INSERT INTO merge_events (user_id, canonical_claim_id, quest_id, quest_claim_id, match_kind, state, justification, decided_by, decided_at)
   VALUES ('$ALICE', '$CC1', '$QA', '$K7', 'exact', 'reversed', 'reversal without an operator', '$ALICE', now());"

probe "X06 second ACTIVE merge lifecycle for the same quest claim" \
  "uq_merge_events_active_per_claim" \
  "INSERT INTO merge_events (user_id, canonical_claim_id, quest_id, quest_claim_id, match_kind, state, justification)
   VALUES ('$ALICE', '$CC2', '$QA', '$K4', 'exact', 'candidate', 'k4 already has an approved lifecycle at CC1');"

probe "X07 cross-user merge: alice's event targeting bob's claim (D6/D3)" \
  "fk_merge_events_claim" \
  "INSERT INTO merge_events (user_id, canonical_claim_id, quest_id, quest_claim_id, match_kind, state, justification)
   VALUES ('$ALICE', '$CC1', '$QC', 'f0000000-0000-4000-8000-000000000021', 'exact', 'candidate', 'bob has no such claim id anyway');"

probe "X08 merge into another user's canonical claim (hub tenancy)" \
  "fk_merge_events_canonical" \
  "INSERT INTO merge_events (user_id, canonical_claim_id, quest_id, quest_claim_id, match_kind, state, justification)
   VALUES ('$BOB', '$CC1', '$QA', '$GK', 'exact', 'candidate', 'bob proposing into alice-owned canonical claim');"

probe "X09 merge event session from another quest (audit chain coherence)" \
  "fk_merge_events_session" \
  "INSERT INTO merge_events (user_id, canonical_claim_id, quest_id, quest_claim_id, match_kind, state, justification, proposed_session_id)
   VALUES ('$ALICE', '$CC1', '$QA', '$GK', 'exact', 'candidate', 'session belongs to another quest', 'e0000000-0000-4000-8000-000000000011');"

probe "X10 blank merge justification (what/why is mandatory)" \
  "ck_merge_events_justification_nonempty" \
  "INSERT INTO merge_events (user_id, canonical_claim_id, quest_id, quest_claim_id, match_kind, state, justification)
   VALUES ('$ALICE', '$CC1', '$QA', '$K7', 'exact', 'candidate', '   ');"

# ---- canonical hub ----
probe "X11 duplicate canonical text per user (exactMatch one-row law)" \
  "uq_canonical_claims_user_text" \
  "INSERT INTO canonical_claims (user_id, canonical_text, urn)
   VALUES ('$ALICE', (SELECT canonical_text FROM canonical_claims WHERE id = '$CC1'), 'kb:cclaim:8888888881');"

probe "X12 canonical claim URN not in kb:cclaim:base58 format (DR-03)" \
  "ck_canonical_claims_urn_format" \
  "INSERT INTO canonical_claims (user_id, canonical_text, urn)
   VALUES ('$ALICE', 'Another distinct control canonical text.', 'kb:claim:notbase58');"

probe "X13 canonical terminal type outside the closed set" \
  "ck_canonical_claims_terminal_type" \
  "INSERT INTO canonical_claims (user_id, canonical_text, urn, terminal_type, terminal_basis)
   VALUES ('$ALICE', 'A control canonical claim with a bad terminal.', 'kb:cclaim:7777777771', 'pooled-estimate', 'future I21 door');"

probe "X14 canonical terminal basis present without a type (pairing)" \
  "ck_canonical_claims_terminal_pair" \
  "INSERT INTO canonical_claims (user_id, canonical_text, urn, terminal_basis)
   VALUES ('$ALICE', 'A control canonical claim with a dangling basis.', 'kb:cclaim:6666666661', 'basis without a type');"

# ---- lifecycle / archive ----
probe "X15 illegal lifecycle transition complete -> active (continuations are new quests)" \
  "ck_quest_lifecycle_transition" \
  "INSERT INTO quest_lifecycle_events (user_id, quest_id, from_state, to_state, actor, occurred_at)
   VALUES ('$ALICE', '$QA', 'complete', 'active', 'operator', now());"

probe "X16 archive twice (archive is once-only)" \
  "uq_quest_lifecycle_archive_once" \
  "INSERT INTO quest_lifecycle_events (user_id, quest_id, from_state, to_state, actor,
                                       verification_phase_id, claims_at_archive, evidence_at_archive, frontier_open_at_archive, occurred_at)
   VALUES ('$ALICE', '$QD', 'complete', 'archived', 'operator', '$PD16', 3, 3, 0, now());"

probe "X17 archive without a verification phase (archive-immutable AFTER verification)" \
  "ck_quest_lifecycle_archive_pair" \
  "INSERT INTO quest_lifecycle_events (user_id, quest_id, from_state, to_state, actor,
                                       claims_at_archive, evidence_at_archive, frontier_open_at_archive, occurred_at)
   VALUES ('$ALICE', '$QA', 'complete', 'archived', 'operator', 7, 8, 2, now());"

probe "X18 archive citing a DECOMPOSE phase as its verification gate" \
  "fk_quest_lifecycle_verification" \
  "INSERT INTO quests (id, user_id, topic, state, provenance_kind, web_call_budget, token_budget, spend_budget_usd)
   VALUES ('b0000000-0000-4000-8000-0000000000e0', '$ALICE', 'Probe quest G (decompose-as-verification attempt)', 'complete', 'fresh', 10, 1000, 1.0);
   INSERT INTO phases (id, user_id, quest_id, kind, round_no, attempt_no, state, started_at, ended_at)
   VALUES ('d0000000-0000-4000-8000-0000000000e1', '$ALICE', 'b0000000-0000-4000-8000-0000000000e0', 'decompose', 1, 1, 'complete', now(), now()),
          ('d0000000-0000-4000-8000-0000000000e2', '$ALICE', 'b0000000-0000-4000-8000-0000000000e0', 'verification', 1, 1, 'complete', now(), now());
   INSERT INTO quest_lifecycle_events (user_id, quest_id, from_state, to_state, actor,
                                       verification_phase_id, claims_at_archive, evidence_at_archive, frontier_open_at_archive, occurred_at)
   VALUES ('$ALICE', 'b0000000-0000-4000-8000-0000000000e0', 'complete', 'archived', 'operator',
           'd0000000-0000-4000-8000-0000000000e1', 0, 0, 0, now());"

probe "X19 archive citing a still-RUNNING verification phase (state pin)" \
  "fk_quest_lifecycle_verification" \
  "INSERT INTO quests (id, user_id, topic, state, provenance_kind, web_call_budget, token_budget, spend_budget_usd)
   VALUES ('b0000000-0000-4000-8000-0000000000f0', '$ALICE', 'Probe quest F (unverified archive attempt)', 'complete', 'fresh', 10, 1000, 1.0);
   INSERT INTO phases (id, user_id, quest_id, kind, round_no, attempt_no, state, started_at)
   VALUES ('d0000000-0000-4000-8000-0000000000f1', '$ALICE', 'b0000000-0000-4000-8000-0000000000f0', 'verification', 1, 1, 'running', now());
   INSERT INTO quest_lifecycle_events (user_id, quest_id, from_state, to_state, actor,
                                       verification_phase_id, claims_at_archive, evidence_at_archive, frontier_open_at_archive, occurred_at)
   VALUES ('$ALICE', 'b0000000-0000-4000-8000-0000000000f0', 'complete', 'archived', 'operator',
           'd0000000-0000-4000-8000-0000000000f1', 0, 0, 0, now());"

probe "X20 archive without pinned graph counts (freeze fingerprint)" \
  "ck_quest_lifecycle_archive_counts_pair" \
  "INSERT INTO phases (id, user_id, quest_id, kind, round_no, attempt_no, state, started_at, ended_at)
   VALUES ('d0000000-0000-4000-8000-0000000000f2', '$ALICE', 'b0000000-0000-4000-8000-0000000000f0', 'verification', 1, 2, 'complete', now(), now());
   INSERT INTO quest_lifecycle_events (user_id, quest_id, from_state, to_state, actor, verification_phase_id, occurred_at)
   VALUES ('$ALICE', 'b0000000-0000-4000-8000-0000000000f0', 'complete', 'archived', 'operator',
           'd0000000-0000-4000-8000-0000000000f2', now());"

probe "X21 negative archive count (counts are nonnegative)" \
  "ck_qle_claims_nonneg" \
  "INSERT INTO quest_lifecycle_events (user_id, quest_id, from_state, to_state, actor,
                                       verification_phase_id, claims_at_archive, evidence_at_archive, frontier_open_at_archive, occurred_at)
   VALUES ('$ALICE', 'b0000000-0000-4000-8000-0000000000f0', 'complete', 'archived', 'operator',
           'd0000000-0000-4000-8000-0000000000f2', -1, 0, 0, now());"

# ---- report versions ----
probe "X22 report version with a DECOMPOSE phase as synthesis lineage" \
  "fk_report_versions_phase" \
  "INSERT INTO report_versions (user_id, quest_id, version_seq, synthesis_phase_id, created_session_id, model, body_blob_key, body_sha256)
   VALUES ('$ALICE', '$QD', 9, '$PD11', 'e0000000-0000-4000-8000-000000000011', 'glm-5.3',
           'reports/b0000000-0000-4000-8000-000000000010/v9.md', repeat('a', 64));"

probe "X23 duplicate report version_seq per quest (chain order)" \
  "uq_report_versions_quest_seq" \
  "INSERT INTO report_versions (user_id, quest_id, version_seq, synthesis_phase_id, created_session_id, model, body_blob_key, body_sha256)
   VALUES ('$ALICE', '$QD', 2, 'd0000000-0000-4000-8000-000000000013', 'e0000000-0000-4000-8000-000000000013', 'glm-5.3',
           'reports/b0000000-0000-4000-8000-000000000010/v9.md', repeat('b', 64));"

probe "X24 second standing report version (one standing artifact per quest)" \
  "uq_report_versions_one_standing" \
  "UPDATE report_versions SET standing = true WHERE id = '$RV1';"

probe "X25 report version session outside the pinned synthesis phase" \
  "fk_report_versions_session" \
  "INSERT INTO report_versions (user_id, quest_id, version_seq, synthesis_phase_id, created_session_id, model, body_blob_key, body_sha256)
   VALUES ('$ALICE', '$QD', 9, 'd0000000-0000-4000-8000-000000000015', 'e0000000-0000-4000-8000-000000000013', 'glm-5.3',
           'reports/b0000000-0000-4000-8000-000000000010/v9.md', repeat('c', 64));"

probe "X26 bound_at without binding_pass (binding pairing)" \
  "ck_report_versions_binding_pair" \
  "UPDATE report_versions SET bound_at = now() WHERE id = '$RV1';"

probe "X27 report body blob key outside the reports/ layout (D8 placement)" \
  "ck_report_versions_body_key" \
  "INSERT INTO report_versions (user_id, quest_id, version_seq, synthesis_phase_id, created_session_id, model, body_blob_key, body_sha256)
   VALUES ('$ALICE', '$QD', 9, 'd0000000-0000-4000-8000-000000000015', 'e0000000-0000-4000-8000-000000000015', 'glm-5.3',
           'blobs/sha256/ab/somewhere-else.md', repeat('d', 64));"

# ---- report citations / binding ----
probe "X28 duplicate citation ordinal within a report version (binding determinism guard)" \
  "uq_report_citations_ordinal" \
  "INSERT INTO report_citations (user_id, quest_id, report_version_id, ordinal, source_id, source_anchorable, imported)
   VALUES ('$ALICE', '$QD', '$RV2', 2, '$S1', true, false);"

probe "X29 citation ordinal below 1 (ordinals are 1-based)" \
  "ck_report_citations_ordinal" \
  "INSERT INTO report_citations (user_id, quest_id, report_version_id, ordinal, source_id, source_anchorable, imported)
   VALUES ('$ALICE', '$QD', '$RV2', 0, '$S1', true, false);"

probe "X30 import citation without an origin quest (never-silent imports, R-027)" \
  "ck_report_citations_import_pair" \
  "INSERT INTO report_citations (user_id, quest_id, report_version_id, ordinal, imported_source_id, imported_source_anchorable, imported)
   VALUES ('$ALICE', '$QD', '$RV2', 6, '$S7', true, true);"

probe "X31 citation carrying BOTH an in-corpus and an imported source ref" \
  "ck_report_citations_resource_exactly_one" \
  "INSERT INTO report_citations (user_id, quest_id, report_version_id, ordinal, source_id, source_anchorable,
                                 imported_source_id, imported_source_anchorable, imported, import_source_quest_id)
   VALUES ('$ALICE', '$QD', '$RV2', 6, '$S1', true, '$S7', true, true, '$QA');"

probe "X32 citation anchored on an AGENDA source (R-003 never citable)" \
  "fk_report_citations_source" \
  "INSERT INTO report_citations (user_id, quest_id, report_version_id, ordinal, source_id, source_anchorable, imported)
   VALUES ('$ALICE', '$QD', '$RV2', 6, '$S5', true, false);"

probe "X33 imported citation anchored on an AGENDA source (import door stays citable-only)" \
  "fk_report_citations_imported_source" \
  "INSERT INTO report_citations (user_id, quest_id, report_version_id, ordinal, imported_source_id, imported_source_anchorable,
                                 imported, import_source_quest_id)
   VALUES ('$ALICE', '$QD', '$RV2', 6, '$S5', true, true, '$QA');"

probe "X34 citation wired to a report version of another quest" \
  "fk_report_citations_report" \
  "INSERT INTO report_citations (user_id, quest_id, report_version_id, ordinal, source_id, source_anchorable, imported)
   VALUES ('$ALICE', '$QA', '$RV2', 9, '$S1', true, false);"

# ---- visibility ----
probe "X35 grant with NEITHER resource column set" \
  "ck_resource_grants_resource_exactly_one" \
  "INSERT INTO resource_grants (owner_user_id, grantee_user_id)
   VALUES ('$ALICE', '$BOB');"

probe "X36 grant with BOTH resource columns set" \
  "ck_resource_grants_resource_exactly_one" \
  "INSERT INTO resource_grants (owner_user_id, source_id, canonical_claim_id, grantee_user_id)
   VALUES ('$ALICE', '$S1', '$CC1', '$BOB');"

probe "X37 grant with two grantees (user AND public)" \
  "ck_resource_grants_grantee_exactly_one" \
  "INSERT INTO resource_grants (owner_user_id, source_id, grantee_user_id, is_public)
   VALUES ('$ALICE', '$S2', '$BOB', true);"

probe "X38 cross-visibility leak: bob granting alice's source (owner must own)" \
  "fk_resource_grants_source" \
  "INSERT INTO resource_grants (owner_user_id, source_id, grantee_user_id)
   VALUES ('$BOB', '$S1', '00000000-0000-4000-8000-000000000003');"

probe "X39 grant on another user's canonical claim (hub tenancy)" \
  "fk_resource_grants_canonical" \
  "INSERT INTO resource_grants (owner_user_id, canonical_claim_id, is_public)
   VALUES ('$BOB', '$CC1', true);"

probe "X40 duplicate workspace membership" \
  "pk_workspace_members" \
  "INSERT INTO workspace_members (workspace_id, user_id)
   VALUES ('$WS1', '$ALICE');"

probe "X41 workspace name outside the slug format" \
  "ck_workspaces_name" \
  "INSERT INTO workspaces (name, created_by_user_id)
   VALUES ('Kquest Lab!', '$ALICE');"

echo "== not schema-expressible laws (enforcement points above, header N1-N7) =="
echo "     N1 archived/complete-graph mutation refusal  -> ENTRY 5 tool precondition + ENTRY 6 archive op + X1 drift sweep"
echo "     N2 exact-match text equality at proposal     -> ENTRY 5 merge ops (seed self-verifies)"
echo "     N3 terminal agreement at approval            -> ENTRY 5/6 merge approval op (DR-06 OPERATOR-RULING)"
echo "     N4 citations-exist iff bound (cross-table)   -> ENTRY 5 binding pass + finalization sweep"
echo "     N5 body_sha256 equals blob bytes             -> ENTRY 5 storage seam (L1 class)"
echo "     N6 standing flip atomicity / bound-only      -> ENTRY 5 finalization transaction"
echo "     N7 one-active-writer, pause, cold-boot       -> ENTRY 4 (I01 DR-12)"

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
