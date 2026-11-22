#!/usr/bin/env bash
# ============================================================================
# kquest I02 cross-quest — check-ddl.sh (gate: ddl-runs, AC2)
# ----------------------------------------------------------------------------
# Creates scratch db kquest_i02_check (drop-if-exists), applies in order:
#   1. design/I01-core-model/artifacts/schema.sql   (frozen law — read-only)
#   2. design/I01-core-model/artifacts/seed.sql     (proves no breakage)
#   3. design/I02-cross-quest/artifacts/schema-i02.sql (additive delta)
#   4. design/I02-cross-quest/artifacts/seed-i02.sql   (new fixtures)
# then asserts the I02 seed-contract minimums (Specification, output format)
# and drops the db. Exit 0 only on full success. Runs from any cwd (paths
# resolved relative to this script). plpgsql-free (assert = temp table +
# CHECK constraint — the I01 idiom).
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
I01_DIR="$SCRIPT_DIR/../../I01-core-model/artifacts"
DB="kquest_i02_check"

if command -v psql >/dev/null 2>&1; then
  PSQL="psql"
else
  PSQL="/opt/homebrew/bin/psql"
fi

echo "== check-ddl: scratch database $DB =="
rc=0

"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB" || { echo "FAIL: drop stale db"; exit 1; }
"$PSQL" -q -d postgres -c "CREATE DATABASE $DB" || { echo "FAIL: create scratch db"; exit 1; }
"$PSQL" -q -d "$DB" -c "CREATE EXTENSION vector" \
  || { echo "FAIL: CREATE EXTENSION vector"; "$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"; exit 1; }

echo "== applying I01 schema.sql (read-only law) =="
"$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I01_DIR/schema.sql" || rc=1

if [ $rc -eq 0 ]; then
  echo "== applying I01 seed.sql =="
  "$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$I01_DIR/seed.sql" || rc=1
fi

if [ $rc -eq 0 ]; then
  echo "== applying schema-i02.sql (additive delta) =="
  "$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$SCRIPT_DIR/schema-i02.sql" || rc=1
fi

if [ $rc -eq 0 ]; then
  echo "== applying seed-i02.sql =="
  "$PSQL" -v ON_ERROR_STOP=1 -q -d "$DB" -f "$SCRIPT_DIR/seed-i02.sql" || rc=1
fi

if [ $rc -eq 0 ]; then
  echo "== asserting I02 seed-contract minimums (Specification, output format) =="
  "$PSQL" -v ON_ERROR_STOP=1 -d "$DB" <<'SQL' || rc=1
CREATE TEMP TABLE ddl_asserts (check_name text PRIMARY KEY, ok boolean NOT NULL);
INSERT INTO ddl_asserts (check_name, ok) VALUES
  -- canonical hub (R-019)
  ('canonical_claims >= 3',                  (SELECT count(*) >= 3 FROM canonical_claims)),
  ('canonical claims with adopted terminal >= 1', (SELECT count(*) >= 1 FROM canonical_claims WHERE terminal_type IS NOT NULL)),
  ('merge_events >= 6',                      (SELECT count(*) >= 6 FROM merge_events)),
  ('merge candidate >= 1',                   (SELECT count(*) >= 1 FROM merge_events WHERE state = 'candidate')),
  ('merge proposed >= 1',                    (SELECT count(*) >= 1 FROM merge_events WHERE state = 'proposed')),
  ('merge approved >= 2',                    (SELECT count(*) >= 2 FROM merge_events WHERE state = 'approved')),
  ('merge rejected (near_dup) >= 1',         (SELECT count(*) >= 1 FROM merge_events WHERE state = 'rejected' AND match_kind = 'near_dup')),
  ('merge reversed >= 1',                    (SELECT count(*) >= 1 FROM merge_events WHERE state = 'reversed')),
  ('one active merge lifecycle per claim',   (SELECT count(*) = 0 FROM (
      SELECT quest_claim_id FROM merge_events
      WHERE state IN ('candidate','proposed','approved')
      GROUP BY quest_claim_id HAVING count(*) > 1) t)),
  ('reversed merge leaves no live member',   (SELECT count(*) = 0 FROM (
      SELECT DISTINCT quest_claim_id FROM merge_events WHERE state = 'reversed') r
      JOIN v_canonical_members m ON m.quest_claim_id = r.quest_claim_id)),
  -- lineage (R-021)
  ('from_corpus quest with inherited corpus', (SELECT count(*) >= 1 FROM quests q
      WHERE q.provenance_kind = 'from_corpus' AND q.source_quest_id IS NOT NULL
        AND (SELECT count(*) FROM quest_sources qs
             WHERE qs.quest_id = q.id) >= 4)),
  ('continuation quest (graph_graft) >= 1',  (SELECT count(*) >= 1 FROM quests WHERE provenance_kind = 'graph_graft')),
  ('grafted claims (origin stamp) >= 3',     (SELECT count(*) >= 3 FROM claims WHERE origin_quest_id IS NOT NULL)),
  ('continuation frontier drained to zero',  (SELECT count(*) >= 1 FROM quests q
      WHERE q.provenance_kind = 'graph_graft'
        AND (SELECT count(*) FROM frontier_entries f
             WHERE f.quest_id = q.id AND f.state = 'open') = 0)),
  ('corpus inheritance is at-init copy (s7 in A, not in D)', (SELECT count(*) = 1 FROM (
      SELECT (EXISTS (SELECT 1 FROM quest_sources qa
                      WHERE qa.quest_id = 'b0000000-0000-4000-8000-000000000001'
                        AND qa.source_id = 'a0000000-0000-4000-8000-000000000007')
              AND NOT EXISTS (SELECT 1 FROM quest_sources qd
                              WHERE qd.quest_id = 'b0000000-0000-4000-8000-000000000010'
                                AND qd.source_id = 'a0000000-0000-4000-8000-000000000007')) AS snap) s
      WHERE s.snap)),
  -- lifecycle (R-022)
  ('lifecycle events >= 2',                  (SELECT count(*) >= 2 FROM quest_lifecycle_events)),
  ('archived quests >= 1',                   (SELECT count(*) >= 1 FROM quests WHERE state = 'archived')),
  ('archive event pins completed verification + counts', (SELECT count(*) >= 1 FROM quest_lifecycle_events e
      JOIN phases p ON p.id = e.verification_phase_id
      WHERE e.to_state = 'archived' AND p.kind = 'verification' AND p.state = 'complete'
        AND e.claims_at_archive IS NOT NULL AND e.frontier_open_at_archive = 0)),
  -- report versioning (R-023/R-024)
  ('report versions >= 2',                   (SELECT count(*) >= 2 FROM report_versions)),
  ('re-synthesis: >= 2 distinct models',     (SELECT count(DISTINCT model) >= 2 FROM report_versions)),
  ('exactly one standing version per quest', (SELECT count(*) = 0 FROM (
      SELECT quest_id FROM report_versions GROUP BY quest_id
      HAVING count(*) FILTER (WHERE standing) <> 1) t)),
  ('stale (non-standing) version >= 1',      (SELECT count(*) >= 1 FROM report_versions WHERE NOT standing)),
  ('every version pins a synthesis phase',   (SELECT count(*) = 0 FROM report_versions rv
      JOIN phases p ON p.id = rv.synthesis_phase_id WHERE p.kind <> 'synthesis')),
  -- citation binding (R-026/R-027)
  ('bound version with binding_pass >= 1',   (SELECT count(*) >= 1 FROM report_versions WHERE bound_at IS NOT NULL AND binding_pass IS NOT NULL)),
  ('citations >= 3',                         (SELECT count(*) >= 3 FROM report_citations)),
  ('explicit import citation >= 1',          (SELECT count(*) >= 1 FROM report_citations WHERE imported AND import_source_quest_id IS NOT NULL)),
  ('imported citation resolves outside quest corpus', (SELECT count(*) >= 1 FROM report_citations rc
      WHERE rc.imported AND NOT EXISTS (SELECT 1 FROM quest_sources qs
          WHERE qs.quest_id = rc.quest_id AND qs.source_id = rc.imported_source_id))),
  ('in-corpus citations resolve inside quest corpus', (SELECT count(*) = 0 FROM report_citations rc
      WHERE rc.imported = false AND NOT EXISTS (SELECT 1 FROM quest_sources qs
          WHERE qs.quest_id = rc.quest_id AND qs.source_id = rc.source_id))),
  -- visibility (R-025)
  ('users >= 3',                             (SELECT count(*) >= 3 FROM users)),
  ('workspaces >= 1 with >= 2 members',      (SELECT count(*) >= 1 FROM workspaces w
      WHERE (SELECT count(*) FROM workspace_members m WHERE m.workspace_id = w.id) >= 2)),
  ('grants: public >= 2',                    (SELECT count(*) >= 2 FROM resource_grants WHERE is_public)),
  ('grants: user share >= 1',                (SELECT count(*) >= 1 FROM resource_grants WHERE grantee_user_id IS NOT NULL)),
  ('grants: workspace share >= 2',           (SELECT count(*) >= 2 FROM resource_grants WHERE grantee_workspace_id IS NOT NULL)),
  ('private-by-absence source exists',       (SELECT count(*) >= 1 FROM sources s
      WHERE NOT EXISTS (SELECT 1 FROM resource_grants g WHERE g.source_id = s.id))),
  ('canonical claim shared via same mechanism', (SELECT count(*) >= 1 FROM resource_grants WHERE canonical_claim_id IS NOT NULL)),
  -- cross-consistency
  ('archive counts equal live counts (no drift)', (SELECT count(*) = 0 FROM quest_lifecycle_events e
      JOIN quests q ON q.id = e.quest_id
      WHERE e.to_state = 'archived'
        AND (e.claims_at_archive <> (SELECT count(*) FROM claims c WHERE c.quest_id = e.quest_id)
          OR e.evidence_at_archive <> (SELECT count(*) FROM evidence v WHERE v.quest_id = e.quest_id)
          OR e.frontier_open_at_archive <> (SELECT count(*) FROM frontier_entries f
                                            WHERE f.quest_id = e.quest_id AND f.state = 'open')))),
  ('no bare claims after I02 (L6)',          (SELECT count(*) = 0 FROM v_claim_closure WHERE bare)),
  ('latest phase mass snapshot matches live (L4)', (SELECT count(*) = 0 FROM (
      SELECT DISTINCT ON (quest_id) quest_id, frontier_open, frontier_mass
      FROM phases
      WHERE frontier_open IS NOT NULL AND ended_at IS NOT NULL
      ORDER BY quest_id, ended_at DESC, id DESC) last
      LEFT JOIN v_frontier_mass vm ON vm.quest_id = last.quest_id
      WHERE last.frontier_open <> coalesce(vm.open_entries, 0)
        OR last.frontier_mass <> coalesce(vm.mass, 0)));
SELECT check_name, ok FROM ddl_asserts ORDER BY check_name;
ALTER TABLE ddl_asserts ADD CONSTRAINT ck_ddl_asserts CHECK (ok);
SQL
fi

echo "== dropping scratch database $DB =="
"$PSQL" -q -d postgres -c "DROP DATABASE IF EXISTS $DB"

if [ $rc -eq 0 ]; then
  echo "check-ddl: PASS"
  exit 0
else
  echo "check-ddl: FAIL"
  exit 1
fi
