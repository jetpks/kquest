-- ============================================================================
-- kquest I02 cross-quest — additive delta DDL (schema-i02.sql)
-- ----------------------------------------------------------------------------
-- Layers ON TOP of design/I01-core-model/artifacts/schema.sql (frozen,
-- read-only law). Everything here is ADDITIVE: new tables, views, indexes,
-- plus four ALTER TABLE ... ADD CONSTRAINT statements that add UNIQUE KEYS
-- ONLY (no column changes, no I01 file edits — DR-15). Those keys are the
-- composite-FK targets this iteration's cross-table pins require:
--   claims(id, user_id)               — merge_events pins the merged claim
--                                        to its owner (tenancy law, DR-01)
--   sources(id, anchorable)           — imported report citations pin the
--                                        citable-only discriminator without a
--                                        tenancy pin (imports are the
--                                        sanctioned cross-quest read; the
--                                        origin quest stays same-user)
--   phases(id, quest_id, kind)        — report versions pin a SYNTHESIS phase
--   phases(id, quest_id, kind, state) — archive events pin a COMPLETED
--                                        VERIFICATION phase (R-022 schema half)
--
-- Coverage: canonical hub + merge events (R-019/R-020, D3), lineage carriers
-- (R-021), lifecycle + archive gates (R-022), report versioning + stale
-- hygiene (R-023/R-024, L11), visibility access layer (R-025, D6), citation
-- binding + import marking (R-026/R-027). Cross-table laws that CHECK/FK/
-- UNIQUE cannot express live in the constraint catalog (DESIGN §10) at
-- tool-time / phase-gate enforcement points, exactly as I01 DR-09 rules.
-- plpgsql-free (I01 pattern; assert idiom = temp table + CHECK).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- DR-15: composite-FK targets on frozen I01 tables (additive unique keys)
-- ---------------------------------------------------------------------------
ALTER TABLE claims  ADD CONSTRAINT uq_claims_id_user          UNIQUE (id, user_id);
ALTER TABLE sources ADD CONSTRAINT uq_sources_id_anchorable   UNIQUE (id, anchorable);
ALTER TABLE phases  ADD CONSTRAINT uq_phases_id_quest_kind        UNIQUE (id, quest_id, kind);
ALTER TABLE phases  ADD CONSTRAINT uq_phases_id_quest_kind_state  UNIQUE (id, quest_id, kind, state);

-- ---------------------------------------------------------------------------
-- canonical_claims — the per-user hub (R-019, D3, D6).
--   One row per DISTINCT canonical text per user: exactMatch merge semantics
--   (uq_canonical_claims_user_text). URN is the UNSALTED content hash of the
--   canonical text (DR-03): global identity lives at the hub, quest-salted
--   identity stays on claims (I01 DR-06 "the hub re-addresses on merge" =
--   membership, never rewriting quest claim URNs). terminal_type/basis are
--   adopted from the first approved member (DR-06); agreement among members
--   is checked at approval (tool-time, catalog).
-- ---------------------------------------------------------------------------
CREATE TABLE canonical_claims (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL,
  canonical_text text NOT NULL CONSTRAINT ck_canonical_claims_text_nonempty
                 CHECK (char_length(btrim(canonical_text)) > 0),
  urn            text NOT NULL CONSTRAINT ck_canonical_claims_urn_format
                 CHECK (urn ~ '^kb:cclaim:[1-9A-HJ-NP-Za-km-z]{10}$'),
  terminal_type  text CONSTRAINT ck_canonical_claims_terminal_type
                 CHECK (terminal_type IN ('definitional-mathematical', 'primary-empirical', 'residual-uncertainty')),
  terminal_basis text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_canonical_claims_terminal_pair
    CHECK ((terminal_type IS NULL) = (terminal_basis IS NULL)),
  CONSTRAINT ck_canonical_claims_terminal_basis_nonempty
    CHECK (terminal_basis IS NULL OR char_length(btrim(terminal_basis)) > 0),
  -- exactMatch semantics: one hub row per canonical text per user
  CONSTRAINT uq_canonical_claims_user_text UNIQUE (user_id, canonical_text),
  CONSTRAINT uq_canonical_claims_user_urn  UNIQUE (user_id, urn),
  -- composite-FK target for merge_events / resource_grants (DR-01 pattern)
  CONSTRAINT uq_canonical_claims_id_user   UNIQUE (id, user_id),
  CONSTRAINT fk_canonical_claims_user FOREIGN KEY (user_id) REFERENCES users (id)
);

-- ---------------------------------------------------------------------------
-- merge_events — propose-only, operator-approved, reversible merges
--   (R-019/R-020, D3). One row per (quest claim, canonical claim) lifecycle:
--   candidate -> proposed -> approved | rejected ; approved -> reversed.
--   Per-row transitions are forward-only (workflow law, tool-time — the
--   merge ops layer refuses walks backward; catalog). The schema halves:
--   - decided states REQUIRE decided_by/decided_at (propose-only: an
--     approved row cannot exist without a recorded human decision);
--   - reversal requires reversed_by/reversed_at + a nonempty reversal_note;
--   - near_dup requires a similarity score, exact forbids one (the near-dup
--     leg is the designated slot ENTRY 3 wires to embeddings);
--   - at most ONE ACTIVE (candidate/proposed/approved) event per quest claim;
--   - same-user only: both endpoints pinned to the row's owner (cross-user
--     merges ride the visibility layer's grants — deferred door, DR-02).
--   Reversal NEVER mutates quest claims or canonical rows: membership is the
--   set of live approved events (v_canonical_members); un-merging flips the
--   event state and the audit trail stays on the row (DR-05).
-- ---------------------------------------------------------------------------
CREATE TABLE merge_events (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid NOT NULL,
  canonical_claim_id  uuid NOT NULL,
  quest_id            uuid NOT NULL,          -- the quest claim's quest
  quest_claim_id      uuid NOT NULL,
  match_kind          text NOT NULL CONSTRAINT ck_merge_events_match_kind
                      CHECK (match_kind IN ('exact', 'near_dup')),
  similarity          numeric(5,4),
  state               text NOT NULL DEFAULT 'candidate' CONSTRAINT ck_merge_events_state
                      CHECK (state IN ('candidate', 'proposed', 'approved', 'rejected', 'reversed')),
  justification       text NOT NULL CONSTRAINT ck_merge_events_justification_nonempty
                      CHECK (char_length(btrim(justification)) > 0),
  proposed_session_id uuid,                   -- which session proposed (R-019)
  decided_by          uuid,                   -- operator who approved/rejected
  decided_at          timestamptz,
  decision_note       text,
  reversed_by         uuid,
  reversed_at         timestamptz,
  reversal_note       text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_merge_events_similarity_range
    CHECK (similarity IS NULL OR (similarity >= 0 AND similarity <= 1)),
  CONSTRAINT ck_merge_events_similarity_pair
    CHECK ((match_kind = 'near_dup') = (similarity IS NOT NULL)),
  CONSTRAINT ck_merge_events_decision_pair CHECK (
    (state IN ('candidate', 'proposed')
       AND decided_by IS NULL AND decided_at IS NULL)
    OR (state IN ('approved', 'rejected', 'reversed')
       AND decided_by IS NOT NULL AND decided_at IS NOT NULL)),
  CONSTRAINT ck_merge_events_reversal_pair CHECK (
    (state = 'reversed') = (reversed_by IS NOT NULL AND reversed_at IS NOT NULL)),
  CONSTRAINT ck_merge_events_reversal_note_nonempty
    CHECK (state <> 'reversed' OR char_length(btrim(reversal_note)) > 0),
  CONSTRAINT ck_merge_events_decision_note_nonempty
    CHECK (decision_note IS NULL OR char_length(btrim(decision_note)) > 0),
  CONSTRAINT fk_merge_events_canonical
    FOREIGN KEY (canonical_claim_id, user_id) REFERENCES canonical_claims (id, user_id),
  CONSTRAINT fk_merge_events_claim
    FOREIGN KEY (quest_claim_id, user_id) REFERENCES claims (id, user_id),
  CONSTRAINT fk_merge_events_claim_quest
    FOREIGN KEY (quest_claim_id, quest_id) REFERENCES claims (id, quest_id),
  CONSTRAINT fk_merge_events_quest
    FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_merge_events_session
    FOREIGN KEY (proposed_session_id, quest_id) REFERENCES sessions (id, quest_id),
  CONSTRAINT fk_merge_events_decided_by FOREIGN KEY (decided_by) REFERENCES users (id),
  CONSTRAINT fk_merge_events_reversed_by FOREIGN KEY (reversed_by) REFERENCES users (id)
);

-- one ACTIVE lifecycle per quest claim (reversed/rejected rows never block
-- a re-proposal — that is the reversibility mechanics, DR-05)
CREATE UNIQUE INDEX uq_merge_events_active_per_claim ON merge_events (quest_claim_id)
  WHERE state IN ('candidate', 'proposed', 'approved');
CREATE INDEX idx_merge_events_canonical ON merge_events (canonical_claim_id, state);

-- ---------------------------------------------------------------------------
-- quest_lifecycle_events — the audited quest state machine (R-022).
--   records every quest.state transition with the LEGAL pair set as a named
--   CHECK (the state diagram, machine-checkable). The ARCHIVE gates:
--   - archive is once-only (partial unique);
--   - archive REQUIRES a COMPLETED VERIFICATION phase — pinned by composite
--     FK with kind/state literals, so "archive-immutable AFTER verification"
--     is schema law, not workflow hope (DR-09);
--   - archive pins the graph counts (claims/evidence/frontier_open) at the
--     moment of freezing: drift is detectable forever after (queries-i02
--     cross-consistency assert; tool-time sweep at the archive op).
--   Transition pairs: paused is the interactive door (D5); stopped -> active
--   is the phase-cap restart precedent (arc-run llm-trading v4); complete is
--   terminal — continuations are NEW quests, never re-opened ones.
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
--   the standing flag (at most ONE standing version per quest), and the
--   binding-pass stamp (R-026: bound_at + binding_pass are paired).
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
--   Serves sources now and canonical claims in the same shape (reports and
--   quests are future additive kinds — DR-14). Exactly-one CHECKs keep the
--   polymorphism honest WITHOUT a polymorphic FK: each resource column is a
--   real composite FK to its owner table, and the owner must OWN the
--   resource (cross-visibility leaks are structurally impossible).
-- ---------------------------------------------------------------------------
CREATE TABLE resource_grants (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id        uuid NOT NULL,
  source_id            uuid,
  canonical_claim_id   uuid,
  grantee_user_id      uuid,
  grantee_workspace_id uuid,
  is_public            boolean NOT NULL DEFAULT false,
  note                 text,
  granted_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_resource_grants_resource_exactly_one
    CHECK ((source_id IS NULL) <> (canonical_claim_id IS NULL)),
  CONSTRAINT ck_resource_grants_grantee_exactly_one
    CHECK ((grantee_user_id IS NOT NULL)::int + (grantee_workspace_id IS NOT NULL)::int + (is_public::int) = 1),
  CONSTRAINT fk_resource_grants_owner FOREIGN KEY (owner_user_id) REFERENCES users (id),
  CONSTRAINT fk_resource_grants_source
    FOREIGN KEY (source_id, owner_user_id) REFERENCES sources (id, user_id),
  CONSTRAINT fk_resource_grants_canonical
    FOREIGN KEY (canonical_claim_id, owner_user_id) REFERENCES canonical_claims (id, user_id),
  CONSTRAINT fk_resource_grants_grantee_user FOREIGN KEY (grantee_user_id) REFERENCES users (id),
  CONSTRAINT fk_resource_grants_grantee_workspace FOREIGN KEY (grantee_workspace_id) REFERENCES workspaces (id)
);
CREATE INDEX idx_resource_grants_grantee_user ON resource_grants (grantee_user_id);
CREATE INDEX idx_resource_grants_grantee_workspace ON resource_grants (grantee_workspace_id);

-- ============================================================================
-- Schema-owned query surface (I01 §3.17 pattern: one definition, every
-- consumer — gates, tools and the hub queries below read these views).
-- ============================================================================

-- Hub membership = the LIVE approved merge events (reversal flips state, so
-- a reversed approval drops out without deleting anything — DR-05).
-- DISTINCT ON takes the newest decided_at per quest claim, guarding any
-- future re-approval after reversal (one ACTIVE lifecycle is already
-- enforced by uq_merge_events_active_per_claim).
CREATE VIEW v_canonical_members AS
SELECT DISTINCT ON (me.quest_claim_id)
       me.user_id,
       me.canonical_claim_id,
       me.quest_claim_id,
       me.quest_id,
       me.id AS merge_event_id,
       me.decided_at
FROM merge_events me
WHERE me.state = 'approved'
ORDER BY me.quest_claim_id, me.decided_at DESC;

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
-- private resources have NO row here (absence = private). One definition
-- over both resource kinds — the "one mechanism" made queryable.
CREATE VIEW v_resource_visibility AS
SELECT 'source'::text AS resource_kind,
       rg.source_id AS resource_id,
       rg.owner_user_id,
       CASE WHEN bool_or(rg.is_public) THEN 'public'::text
            WHEN count(rg.grantee_workspace_id) > 0 THEN 'workspace'::text
            ELSE 'shared'::text END AS effective_scope
FROM resource_grants rg
WHERE rg.source_id IS NOT NULL
GROUP BY rg.source_id, rg.owner_user_id
UNION
SELECT 'canonical_claim'::text,
       rg.canonical_claim_id,
       rg.owner_user_id,
       CASE WHEN bool_or(rg.is_public) THEN 'public'::text
            WHEN count(rg.grantee_workspace_id) > 0 THEN 'workspace'::text
            ELSE 'shared'::text END
FROM resource_grants rg
WHERE rg.canonical_claim_id IS NOT NULL
GROUP BY rg.canonical_claim_id, rg.owner_user_id;
