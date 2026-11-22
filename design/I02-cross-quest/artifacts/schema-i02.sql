-- ============================================================================
-- kquest I02 cross-quest — additive delta DDL (schema-i02.sql)
-- ----------------------------------------------------------------------------
-- Layers ON TOP of design/I01-core-model/artifacts/schema.sql (frozen,
-- read-only law). Everything here is ADDITIVE: new tables, views, indexes,
-- plus three ALTER TABLE ... ADD CONSTRAINT statements that add UNIQUE KEYS
-- ONLY (no column changes, no I01 file edits — DR-15, amended 2026-11-22:
-- the fourth key, claims(id, user_id), is dropped from the set — its only
-- consumer was the excised merge_events FK; DR-16). The remaining keys are
-- the composite-FK targets this iteration's cross-table pins require:
--   sources(id, anchorable)           — imported report citations pin the
--                                        citable-only discriminator without a
--                                        tenancy pin (imports are the
--                                        sanctioned cross-quest read; the
--                                        origin quest stays same-user)
--   phases(id, quest_id, kind)        — report versions pin a SYNTHESIS phase
--   phases(id, quest_id, kind, state) — archive events pin a COMPLETED
--                                        VERIFICATION phase (R-022 schema half)
--
-- Coverage: the canonical hub VIEW (R-019/R-020, D3, DR-16 — demoted from
-- tables to a derived view by the operator ruling of 2026-11-22), lineage
-- carriers (R-021), lifecycle + archive gates with GRAPH FINGERPRINTS
-- (R-022, DR-17 — archive-immutability replaced by fingerprint detection),
-- report versioning + stale hygiene (R-023/R-024, L11), visibility access
-- layer (R-025, D6), citation binding + import marking (R-026/R-027).
-- Cross-table laws that CHECK/FK/UNIQUE cannot express live in the
-- constraint catalog (DESIGN §10) at tool-time / phase-gate enforcement
-- points, exactly as I01 DR-09 rules. plpgsql-free (I01 pattern; assert
-- idiom = temp table + CHECK).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- DR-15 (amended): composite-FK targets on frozen I01 tables (additive keys)
-- ---------------------------------------------------------------------------
ALTER TABLE sources ADD CONSTRAINT uq_sources_id_anchorable   UNIQUE (id, anchorable);
ALTER TABLE phases  ADD CONSTRAINT uq_phases_id_quest_kind        UNIQUE (id, quest_id, kind);
ALTER TABLE phases  ADD CONSTRAINT uq_phases_id_quest_kind_state  UNIQUE (id, quest_id, kind, state);

-- ---------------------------------------------------------------------------
-- quest_lifecycle_events — the audited state machine (R-022).
--   records every quest.state transition with the LEGAL pair set as a named
--   CHECK (the state diagram, machine-checkable). The ARCHIVE gates:
--   - archive is once-only (partial unique);
--   - archive REQUIRES a COMPLETED VERIFICATION phase — pinned by composite
--     FK with kind/state literals, so "archive AFTER verification"
--     is schema law, not workflow hope (DR-09);
--   - archive pins the graph counts (claims/evidence/frontier_open) AND the
--     GRAPH FINGERPRINT at the moment of freezing (DR-17). Under the
--     fingerprint law the quest is NOT immutable after archive: reworking a
--     completed/archived quest in place is legal, and any drift between the
--     pinned fingerprint and the live graph (v_quest_graph_fingerprint) is
--     DETECTED, not prevented — the ENTRY 7 staleness tripwire's data.
--   Transition pairs: paused is the interactive door (D5); stopped -> active
--   is the phase-cap restart precedent (arc-run llm-trading v4); complete is
--   terminal in the LEDGER — continuations are NEW quests, never re-opened
--   ones (the ledger law survives; the immutability law does not, DR-17).
--   NOTE: the ledger records transitions; keeping quests.state in sync with
--   the ledger is the lifecycle op's job (tool-time, catalog).
-- ---------------------------------------------------------------------------
CREATE TABLE quest_lifecycle_events (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                  uuid NOT NULL,
  quest_id                 uuid NOT NULL,
  from_state               text NOT NULL CONSTRAINT ck_qle_from_state
                           CHECK (from_state IN ('active', 'paused', 'complete', 'stopped', 'archived')),
  to_state                 text NOT NULL CONSTRAINT ck_qle_to_state
                           CHECK (to_state IN ('active', 'paused', 'complete', 'stopped', 'archived')),
  actor                    text NOT NULL CONSTRAINT ck_qle_actor
                           CHECK (actor IN ('operator', 'orchestrator')),
  verification_phase_id    uuid,
  -- literal pins: an archive event can only point at a phase whose kind is
  -- 'verification' and whose state is 'complete' (FK below; DR-09)
  verification_phase_kind  text NOT NULL DEFAULT 'verification'
                           CONSTRAINT ck_qle_verification_kind CHECK (verification_phase_kind = 'verification'),
  verification_phase_state text NOT NULL DEFAULT 'complete'
                           CONSTRAINT ck_qle_verification_state CHECK (verification_phase_state = 'complete'),
  claims_at_archive        integer CONSTRAINT ck_qle_claims_nonneg
                           CHECK (claims_at_archive IS NULL OR claims_at_archive >= 0),
  evidence_at_archive      integer CONSTRAINT ck_qle_evidence_nonneg
                           CHECK (evidence_at_archive IS NULL OR evidence_at_archive >= 0),
  frontier_open_at_archive integer CONSTRAINT ck_qle_frontier_open_nonneg
                           CHECK (frontier_open_at_archive IS NULL OR frontier_open_at_archive >= 0),
  -- DR-17: the fingerprint of the quest's graph+corpus state AT FREEZE
  -- (algorithm: v_quest_graph_fingerprint; spec: DESIGN §6)
  graph_fingerprint        char(64) CONSTRAINT ck_qle_graph_fingerprint_format
                           CHECK (graph_fingerprint IS NULL OR graph_fingerprint::text ~ '^[0-9a-f]{64}$'),
  occurred_at              timestamptz NOT NULL,
  note                     text,
  created_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_quest_lifecycle_transition CHECK ((from_state, to_state) IN (
      ('active',  'paused'),
      ('paused',  'active'),
      ('active',  'complete'),
      ('paused',  'complete'),
      ('active',  'stopped'),
      ('paused',  'stopped'),
      ('stopped', 'active'),
      ('complete','archived'),
      ('stopped', 'archived'))),
  CONSTRAINT ck_quest_lifecycle_archive_pair
    CHECK ((to_state = 'archived') = (verification_phase_id IS NOT NULL)),
  CONSTRAINT ck_quest_lifecycle_archive_counts_pair
    CHECK ((to_state = 'archived') = (claims_at_archive IS NOT NULL
                                  AND evidence_at_archive IS NOT NULL
                                  AND frontier_open_at_archive IS NOT NULL)),
  CONSTRAINT ck_quest_lifecycle_archive_fingerprint_pair
    CHECK ((to_state = 'archived') = (graph_fingerprint IS NOT NULL)),
  CONSTRAINT fk_qle_quest FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_quest_lifecycle_verification
    FOREIGN KEY (verification_phase_id, quest_id, verification_phase_kind, verification_phase_state)
    REFERENCES phases (id, quest_id, kind, state)
);

-- archive is once-only per quest
CREATE UNIQUE INDEX uq_quest_lifecycle_archive_once ON quest_lifecycle_events (quest_id)
  WHERE to_state = 'archived';
CREATE INDEX idx_qle_quest ON quest_lifecycle_events (quest_id, occurred_at);

-- ---------------------------------------------------------------------------
-- report_versions — reports are views; versions are rows ABOUT the views
--   (R-023, L11, D8). The body itself is an object-storage blob (content-
--   hashed); this row is the version chain link: which synthesis phase and
--   session produced it (graph lineage — pinned by composite FKs, including
--   the phase-KIND literal so a report version can never claim a decompose
--   or verification phase), which model wrote it (re-synthesis economics),
--   the standing flag (at most ONE standing version per quest), the
--   binding-pass stamp (R-026: bound_at + binding_pass are paired), and the
--   PINNED QUEST FINGERPRINT (DR-17): the graph fingerprint at synthesis
--   time. A version whose pin differs from the live fingerprint is STALE —
--   visible, sweep-detectable (queries-i02.sql M3), never silently fresh.
--   Stale hygiene (R-024): superseded versions keep standing=false forever;
--   the standing flip is the finalization op's transaction (tool-time).
-- ---------------------------------------------------------------------------
CREATE TABLE report_versions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid NOT NULL,
  quest_id             uuid NOT NULL,
  version_seq          integer NOT NULL CONSTRAINT ck_report_versions_seq CHECK (version_seq >= 1),
  synthesis_phase_id   uuid NOT NULL,
  synthesis_phase_kind text NOT NULL DEFAULT 'synthesis'
                       CONSTRAINT ck_report_versions_phase_kind CHECK (synthesis_phase_kind = 'synthesis'),
  created_session_id   uuid NOT NULL,
  model                text NOT NULL CONSTRAINT ck_report_versions_model_nonempty
                       CHECK (char_length(btrim(model)) > 0),
  body_blob_key        text NOT NULL CONSTRAINT ck_report_versions_body_key
                       CHECK (body_blob_key ~ '^reports/[0-9a-f-]{36}/v[0-9]+\.md$'),
  body_sha256          char(64) NOT NULL CONSTRAINT ck_report_versions_body_sha
                       CHECK (body_sha256::text ~ '^[0-9a-f]{64}$'),
  -- DR-17: the graph fingerprint this version was synthesized against
  -- (same format law as body_sha256; same algorithm as archive rows)
  quest_fingerprint    char(64) NOT NULL CONSTRAINT ck_report_versions_quest_fingerprint
                       CHECK (quest_fingerprint::text ~ '^[0-9a-f]{64}$'),
  standing             boolean NOT NULL DEFAULT false,
  bound_at             timestamptz,
  binding_pass         text CONSTRAINT ck_report_versions_binding_pass_nonempty
                       CHECK (binding_pass IS NULL OR char_length(btrim(binding_pass)) > 0),
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_report_versions_binding_pair
    CHECK ((bound_at IS NULL) = (binding_pass IS NULL)),
  CONSTRAINT uq_report_versions_quest_seq UNIQUE (quest_id, version_seq),
  CONSTRAINT uq_report_versions_id_quest  UNIQUE (id, quest_id),
  CONSTRAINT fk_report_versions_quest
    FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_report_versions_phase
    FOREIGN KEY (synthesis_phase_id, quest_id, synthesis_phase_kind)
    REFERENCES phases (id, quest_id, kind),
  CONSTRAINT fk_report_versions_session
    FOREIGN KEY (created_session_id, synthesis_phase_id) REFERENCES sessions (id, phase_id)
);

-- the standing-artifact pointer: at most one standing version per quest
CREATE UNIQUE INDEX uq_report_versions_one_standing ON report_versions (quest_id) WHERE standing;
CREATE INDEX idx_report_versions_quest ON report_versions (quest_id, version_seq);

-- ---------------------------------------------------------------------------
-- report_citations — the deterministic binding pass OUTPUT (R-026/R-027).
--   One row per inline ordinal of a bound report version: ordinal -> source.
--   In-corpus citations pin the source through the citable-only conditional
--   FK (same discriminator pattern as evidence — R-003 "never citable").
--   Explicit imports (R-027: own-corpus or MARKED imports, never silent)
--   carry imported_source_id (citable-only pinned across users via
--   uq_sources_id_anchorable) + the origin quest (same-user, I01 §7 posture;
--   cross-user origins ride the visibility layer when quest sharing lands).
-- ---------------------------------------------------------------------------
CREATE TABLE report_citations (
  id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                    uuid NOT NULL,
  quest_id                   uuid NOT NULL,
  report_version_id          uuid NOT NULL,
  ordinal                    integer NOT NULL CONSTRAINT ck_report_citations_ordinal CHECK (ordinal >= 1),
  source_id                  uuid,
  source_anchorable          boolean NOT NULL DEFAULT true
                             CONSTRAINT ck_report_citations_citable CHECK (source_anchorable),
  imported_source_id         uuid,
  imported_source_anchorable boolean NOT NULL DEFAULT true
                             CONSTRAINT ck_report_citations_import_citable CHECK (imported_source_anchorable),
  imported                   boolean NOT NULL DEFAULT false,
  import_source_quest_id     uuid,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_report_citations_resource_exactly_one
    CHECK ((source_id IS NULL) <> (imported_source_id IS NULL)),
  CONSTRAINT ck_report_citations_import_pair
    CHECK (imported = (imported_source_id IS NOT NULL)
       AND imported = (import_source_quest_id IS NOT NULL)),
  CONSTRAINT uq_report_citations_ordinal   UNIQUE (report_version_id, ordinal),
  CONSTRAINT uq_report_citations_id_version UNIQUE (id, report_version_id),
  CONSTRAINT fk_report_citations_report
    FOREIGN KEY (report_version_id, quest_id) REFERENCES report_versions (id, quest_id),
  CONSTRAINT fk_report_citations_quest
    FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_report_citations_source
    FOREIGN KEY (source_id, user_id, source_anchorable) REFERENCES sources (id, user_id, anchorable),
  CONSTRAINT fk_report_citations_imported_source
    FOREIGN KEY (imported_source_id, imported_source_anchorable) REFERENCES sources (id, anchorable),
  CONSTRAINT fk_report_citations_import_quest
    FOREIGN KEY (import_source_quest_id, user_id) REFERENCES quests (id, user_id)
);
CREATE INDEX idx_report_citations_source ON report_citations (source_id);

-- ---------------------------------------------------------------------------
-- workspaces / workspace_members — the workspace door's group primitive
--   (R-025, D6). Deliberately minimal: named workspace + members. Scoping of
--   RESOURCES (not of tenants' own data) is the grants table below.
-- ---------------------------------------------------------------------------
CREATE TABLE workspaces (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name               text NOT NULL CONSTRAINT ck_workspaces_name
                     CHECK (name ~ '^[a-z0-9][a-z0-9-]{0,63}$'),
  created_by_user_id uuid NOT NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_workspaces_name UNIQUE (name),
  CONSTRAINT fk_workspaces_creator FOREIGN KEY (created_by_user_id) REFERENCES users (id)
);

CREATE TABLE workspace_members (
  workspace_id uuid NOT NULL,
  user_id      uuid NOT NULL,
  joined_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pk_workspace_members PRIMARY KEY (workspace_id, user_id),
  CONSTRAINT fk_workspace_members_workspace FOREIGN KEY (workspace_id) REFERENCES workspaces (id),
  CONSTRAINT fk_workspace_members_user FOREIGN KEY (user_id) REFERENCES users (id)
);
CREATE INDEX idx_workspace_members_user ON workspace_members (user_id);

-- ---------------------------------------------------------------------------
-- resource_grants — ONE sharing mechanism, additive over ownership
--   (R-025, D6). Scope ladder: private (default = NO row) < shared (user
--   grant) < workspace (workspace grant) < public (the global door).
--   Serves SOURCES now (DR-14, amended by DR-16: the canonical-claim grant
--   kind is deferred with the materialized hub — the hub is a derived view
--   and holds no rows to grant on; the kind returns as an additive nullable
--   column + composite FK when ENTRY 3+ materializes hub identity). Exactly
--   one grantee keeps the polymorphism honest WITHOUT a polymorphic FK.
-- ---------------------------------------------------------------------------
CREATE TABLE resource_grants (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id        uuid NOT NULL,
  source_id            uuid NOT NULL,
  grantee_user_id      uuid,
  grantee_workspace_id uuid,
  is_public            boolean NOT NULL DEFAULT false,
  note                 text,
  granted_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_resource_grants_grantee_exactly_one
    CHECK ((grantee_user_id IS NOT NULL)::int + (grantee_workspace_id IS NOT NULL)::int + (is_public::int) = 1),
  CONSTRAINT fk_resource_grants_owner FOREIGN KEY (owner_user_id) REFERENCES users (id),
  CONSTRAINT fk_resource_grants_source
    FOREIGN KEY (source_id, owner_user_id) REFERENCES sources (id, user_id),
  CONSTRAINT fk_resource_grants_grantee_user FOREIGN KEY (grantee_user_id) REFERENCES users (id),
  CONSTRAINT fk_resource_grants_grantee_workspace FOREIGN KEY (grantee_workspace_id) REFERENCES workspaces (id)
);
CREATE INDEX idx_resource_grants_grantee_user ON resource_grants (grantee_user_id);
CREATE INDEX idx_resource_grants_grantee_workspace ON resource_grants (grantee_workspace_id);

-- ============================================================================
-- Schema-owned query surface (I01 §3.17 pattern: one definition, every
-- consumer — gates, tools and the hub queries below read these views).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- v_canonical_claims — THE HUB, as a derived view over quest claims
--   (R-019/R-020, D3; DR-16, operator ruling 2026-11-22). Identity =
--   (user_id, canonical_text, terminal_type): exact-text matches with
--   DIFFERING terminal types coexist as distinct entries — nothing is
--   adopted, nothing refused. canonical_text is the I01 DR-05 GENERATED
--   normalization, so the derivation is exactMatch on the normalized form
--   (DR-02 option A, ruled). type_divergent flags same-text entries whose
--   (user, text) carries MORE THAN ONE distinct NON-NULL terminal_type —
--   an unterminated claim (terminal_type IS NULL) is its own entry value
--   and is NOT by itself a divergence; conflicting TYPES are the ENTRY 7
--   tripwire signal, adjudicated in the source quest (the hub is derived).
--   first_seen/latest_seen are informational (min/max claim created_at),
--   not part of identity. Membership is computed, never stored: the view
--   IS the hub (L10 — no derived data to invalidate).
-- ---------------------------------------------------------------------------
CREATE VIEW v_canonical_claims AS
SELECT c.user_id,
       c.canonical_text,
       c.terminal_type,
       array_agg(c.id ORDER BY c.quest_id, c.id) AS member_claim_ids,
       count(DISTINCT c.quest_id)                AS quest_count,
       min(c.created_at)                         AS first_seen,
       max(c.created_at)                         AS latest_seen,
       (count(*) FILTER (WHERE c.terminal_type IS NOT NULL)
          OVER (PARTITION BY c.user_id, c.canonical_text)) > 1 AS type_divergent
FROM claims c
GROUP BY c.user_id, c.canonical_text, c.terminal_type;

-- ---------------------------------------------------------------------------
-- v_quest_graph_fingerprint — the graph+corpus fingerprint (DR-17).
--   fingerprint(q) = hex(sha256(UTF8(S(q)))) where S(q) is the CANONICAL
--   SERIALIZATION below (spec verbatim in DESIGN §6; netstring field
--   encoding: NULL -> 'N', value v -> 'S' || octet_length(UTF8(v)) || ':'
--   || v; fields joined ';', rows joined chr(10), sections prefixed
--   'name:'). Rows are ordered by each table's quest-scoped unique key, so
--   the serialization is a total order on the quest's state. quests.state
--   and all created_at stamps are DELIBERATELY excluded: the fingerprint
--   covers the graph+corpus CONTENT, so a lifecycle transition (e.g. the
--   archive itself) never changes it, while any later claim/evidence/edge/
--   derivation/frontier/corpus change does. One row per quest.
-- ---------------------------------------------------------------------------
CREATE VIEW v_quest_graph_fingerprint AS
SELECT q.id AS quest_id,
       encode(sha256(convert_to(
         'kquest-graph-fingerprint/1' || chr(10)
         || 'corpus:' || coalesce((
              SELECT string_agg(
                CASE WHEN qs.source_id IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(qs.source_id::text, 'UTF8')) || ':' || qs.source_id::text END
                || ';' ||
                CASE WHEN qs.added_at IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to((extract(epoch FROM qs.added_at))::text, 'UTF8'))
                          || ':' || (extract(epoch FROM qs.added_at))::text END,
                chr(10) ORDER BY qs.source_id)
              FROM quest_sources qs WHERE qs.quest_id = q.id), '') || chr(10)
         || 'claims:' || coalesce((
              SELECT string_agg(
                'S' || octet_length(convert_to(c.quest_seq::text, 'UTF8')) || ':' || c.quest_seq::text
                || ';' ||
                CASE WHEN c.id IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(c.id::text, 'UTF8')) || ':' || c.id::text END
                || ';' ||
                CASE WHEN c.canonical_text IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(c.canonical_text, 'UTF8')) || ':' || c.canonical_text END
                || ';' ||
                CASE WHEN c.terminal_type IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(c.terminal_type, 'UTF8')) || ':' || c.terminal_type END
                || ';' ||
                CASE WHEN c.terminal_basis IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(c.terminal_basis, 'UTF8')) || ':' || c.terminal_basis END
                || ';' ||
                CASE WHEN c.origin_quest_id IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(c.origin_quest_id::text, 'UTF8')) || ':' || c.origin_quest_id::text END,
                chr(10) ORDER BY c.quest_seq, c.id)
              FROM claims c WHERE c.quest_id = q.id), '') || chr(10)
         || 'evidence:' || coalesce((
              SELECT string_agg(
                CASE WHEN e.id IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(e.id::text, 'UTF8')) || ':' || e.id::text END
                || ';' ||
                CASE WHEN e.source_id IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(e.source_id::text, 'UTF8')) || ':' || e.source_id::text END
                || ';' ||
                'S' || octet_length(convert_to(e.span_start::text, 'UTF8')) || ':' || e.span_start::text
                || ';' ||
                'S' || octet_length(convert_to(e.span_end::text, 'UTF8')) || ':' || e.span_end::text
                || ';' ||
                CASE WHEN e.span_text IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(e.span_text, 'UTF8')) || ':' || e.span_text END
                || ';' ||
                CASE WHEN e.reading IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(e.reading, 'UTF8')) || ':' || e.reading END,
                chr(10) ORDER BY e.source_id, e.span_start, e.span_end, e.id)
              FROM evidence e WHERE e.quest_id = q.id), '') || chr(10)
         || 'edges:' || coalesce((
              SELECT string_agg(
                CASE WHEN ee.evidence_id IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(ee.evidence_id::text, 'UTF8')) || ':' || ee.evidence_id::text END
                || ';' ||
                CASE WHEN ee.relation IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(ee.relation, 'UTF8')) || ':' || ee.relation END
                || ';' ||
                CASE WHEN ee.claim_id IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(ee.claim_id::text, 'UTF8')) || ':' || ee.claim_id::text END
                || ';' ||
                'S' || octet_length(convert_to(ee.position::text, 'UTF8')) || ':' || ee.position::text,
                chr(10) ORDER BY ee.evidence_id, ee.relation, ee.position)
              FROM evidence_edges ee WHERE ee.quest_id = q.id), '') || chr(10)
         || 'derivations:' || coalesce((
              SELECT string_agg(
                CASE WHEN cd.claim_id IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(cd.claim_id::text, 'UTF8')) || ':' || cd.claim_id::text END
                || ';' ||
                CASE WHEN cd.parent_claim_id IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(cd.parent_claim_id::text, 'UTF8')) || ':' || cd.parent_claim_id::text END
                || ';' ||
                'S' || octet_length(convert_to(cd.position::text, 'UTF8')) || ':' || cd.position::text,
                chr(10) ORDER BY cd.claim_id, cd.position)
              FROM claim_derivations cd WHERE cd.quest_id = q.id), '') || chr(10)
         || 'frontier:' || coalesce((
              SELECT string_agg(
                CASE WHEN f.claim_id IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(f.claim_id::text, 'UTF8')) || ':' || f.claim_id::text END
                || ';' ||
                CASE WHEN f.need IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(f.need, 'UTF8')) || ':' || f.need END
                || ';' ||
                'S' || octet_length(convert_to(f.uncertainty::text, 'UTF8')) || ':' || f.uncertainty::text
                || ';' ||
                'S' || octet_length(convert_to(f.relevance::text, 'UTF8')) || ':' || f.relevance::text
                || ';' ||
                CASE WHEN f.state IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(f.state, 'UTF8')) || ':' || f.state END
                || ';' ||
                CASE WHEN f.closure_type IS NULL THEN 'N'
                     ELSE 'S' || octet_length(convert_to(f.closure_type, 'UTF8')) || ':' || f.closure_type END,
                chr(10) ORDER BY f.need)
              FROM frontier_entries f WHERE f.quest_id = q.id), '')
         , 'UTF8')), 'hex') AS graph_fingerprint
FROM quests q;

-- Quest lineage chain (R-021): every ancestor reachable through
-- quests.source_quest_id, each hop labelled with the DESCENDANT quest's
-- provenance_kind (the stamp that created the edge). Depth-capped at 20 —
-- lineage cycles are impossible (same-user FK + fresh ids) but the cap
-- keeps the view bounded under any future data corruption.
CREATE VIEW v_quest_lineage AS
WITH RECURSIVE lin (quest_id, ancestor_quest_id, via_provenance_kind, depth) AS (
  SELECT q.id, q.source_quest_id, q.provenance_kind, 1
  FROM quests q
  WHERE q.source_quest_id IS NOT NULL
  UNION ALL
  SELECT l.quest_id, q2.source_quest_id, q2.provenance_kind, l.depth + 1
  FROM lin l
  JOIN quests q2 ON q2.id = l.ancestor_quest_id
  WHERE q2.source_quest_id IS NOT NULL AND l.depth < 20
)
SELECT lin.quest_id,
       q.topic,
       lin.ancestor_quest_id,
       qa.topic AS ancestor_topic,
       lin.via_provenance_kind,
       lin.depth
FROM lin
JOIN quests q  ON q.id  = lin.quest_id
JOIN quests qa ON qa.id = lin.ancestor_quest_id;

-- Effective scope per shared resource (R-025): public > workspace > shared;
-- private resources have NO row here (absence = private). Sources now; the
-- "one mechanism" gains arms back as additive kinds (DR-14/DR-16).
CREATE VIEW v_resource_visibility AS
SELECT 'source'::text AS resource_kind,
       rg.source_id AS resource_id,
       rg.owner_user_id,
       CASE WHEN bool_or(rg.is_public) THEN 'public'::text
            WHEN count(rg.grantee_workspace_id) > 0 THEN 'workspace'::text
            ELSE 'shared'::text END AS effective_scope
FROM resource_grants rg
GROUP BY rg.source_id, rg.owner_user_id;
