-- ============================================================================
-- kquest I01 core-model — draft DDL (schema.sql)
-- ----------------------------------------------------------------------------
-- Scope: the core domain model per design/I01-core-model/DESIGN.md.
--   - PoC field semantics carried into DDL where schema-expressible
--     (canonical normalization, per-quest canonical-text uniqueness, frontier
--     ranges/ordering, distinct-needs, citable-only anchoring, offset bounds).
--   - Cross-table laws (closure satisfy_one, terminal XOR derives_from,
--     edge_min) are NOT expressible as CHECK/FK/UNIQUE and live in the
--     constraint catalog (DESIGN.md §5) at tool-time / phase-gate points.
--
-- Conventions:
--   ids          uuid (gen_random_uuid, PG13+ builtin)
--   tenancy      every domain row carries user_id (R-001 law); coherence is
--                enforced by composite FKs to (id, user_id) unique keys.
--   enums        text + CHECK IN (...) — evolvable without ALTER TYPE
--   offsets      Unicode CHARACTER offsets, 0-based, half-open
--                [start, end), into the source's snapshot blob text (L1)
--   timestamps   timestamptz, UTC
--
-- Runs clean on a fresh scratch database (PostgreSQL 18; pgvector extension
-- created here so the file is self-sufficient under psql -f; no vector
-- columns yet — the embedding registry lands in ENTRY 3 and must not
-- conflict with anything below).
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS vector;

-- ---------------------------------------------------------------------------
-- users — tenant root (R-001, D6)
-- ---------------------------------------------------------------------------
CREATE TABLE users (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  handle       text NOT NULL CONSTRAINT ck_users_handle
               CHECK (handle ~ '^[a-z0-9][a-z0-9_-]{1,31}$'),
  display_name text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_users_handle UNIQUE (handle)
);

-- ---------------------------------------------------------------------------
-- sources — fetched, immutable-snapshot corpus units (R-002, R-003, D3, D6, D8)
--   Snapshot + raw response bodies live in object storage; this row is the
--   citation anchor (content-addressed URN, DR-02/DR-04).
--   Blob keys are GENERATED from the sha256 columns (L10 derived-ness:
--   anything derivable is rebuildable; the key template is pinned in DDL).
--   anchorable is the citable-role discriminator used by conditional FKs
--   from evidence / conflict_sources (R-003: agenda sources are never
--   anchorable or citable — natively enforced, DR-07).
-- ---------------------------------------------------------------------------
CREATE TABLE sources (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid NOT NULL,
  url                 text NOT NULL CONSTRAINT ck_sources_url
                      CHECK (url ~ '^https?://'),
  canonical_url       text NOT NULL CONSTRAINT ck_sources_canonical_url
                      CHECK (canonical_url ~ '^https?://'),
  urn                 text NOT NULL CONSTRAINT ck_sources_urn_format
                      CHECK (urn ~ '^kb:src:[1-9A-HJ-NP-Za-km-z]{10}$'),
  title               text NOT NULL CONSTRAINT ck_sources_title_nonempty
                      CHECK (char_length(btrim(title)) > 0),
  role                text NOT NULL CONSTRAINT ck_sources_role
                      CHECK (role IN ('citable', 'agenda')),
  published_at        timestamptz,
  fetched_at          timestamptz NOT NULL,
  snapshot_sha256     char(64) NOT NULL CONSTRAINT ck_sources_snapshot_sha
                      CHECK (snapshot_sha256::text ~ '^[0-9a-f]{64}$'),
  raw_sha256          char(64) NOT NULL CONSTRAINT ck_sources_raw_sha
                      CHECK (raw_sha256::text ~ '^[0-9a-f]{64}$'),
  snapshot_blob_key   text GENERATED ALWAYS AS
                      ('blobs/sha256/' || substr(snapshot_sha256::text, 1, 2) || '/' || snapshot_sha256::text) STORED,
  raw_blob_key        text GENERATED ALWAYS AS
                      ('blobs/sha256/' || substr(raw_sha256::text, 1, 2) || '/' || raw_sha256::text) STORED,
  snapshot_char_count integer NOT NULL CONSTRAINT ck_sources_snapshot_chars
                      CHECK (snapshot_char_count > 0),
  anchorable          boolean GENERATED ALWAYS AS (role = 'citable') STORED,
  created_at          timestamptz NOT NULL DEFAULT now(),
  -- content-address law: one row per (user, snapshot) — same snapshot ⇒ same
  -- URN ⇒ second fetch dedups to the existing row (D3 fetch-once per user)
  CONSTRAINT uq_sources_user_urn UNIQUE (user_id, urn),
  -- composite-FK targets for tenant/coherence laws (DR-01, DR-07, DR-08)
  CONSTRAINT uq_sources_id_user UNIQUE (id, user_id),
  CONSTRAINT uq_sources_id_user_anchorable UNIQUE (id, user_id, anchorable),
  CONSTRAINT uq_sources_id_user_anchorable_chars
    UNIQUE (id, user_id, anchorable, snapshot_char_count),
  CONSTRAINT fk_sources_user FOREIGN KEY (user_id) REFERENCES users (id)
);

CREATE INDEX idx_sources_user_fetched ON sources (user_id, fetched_at DESC);

-- ---------------------------------------------------------------------------
-- quests — hermetic build units (R-011; D3: claims/evidence/edges/frontier
--   are quest-scoped; D5/L13: paused state is the interactive-pause door;
--   provenance {from_corpus, graph_graft, source_quest_id} per R-011/R-021 —
--   lineage semantics themselves are ENTRY 2)
-- ---------------------------------------------------------------------------
CREATE TABLE quests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL,
  topic            text NOT NULL CONSTRAINT ck_quests_topic_nonempty
                   CHECK (char_length(btrim(topic)) > 0),
  state            text NOT NULL DEFAULT 'active' CONSTRAINT ck_quests_state
                   CHECK (state IN ('active', 'paused', 'complete', 'stopped', 'archived')),
  provenance_kind  text NOT NULL DEFAULT 'fresh' CONSTRAINT ck_quests_provenance
                   CHECK (provenance_kind IN ('fresh', 'from_corpus', 'graph_graft')),
  source_quest_id  uuid,
  web_call_budget  integer NOT NULL CONSTRAINT ck_quests_web_budget CHECK (web_call_budget >= 0),
  token_budget     integer NOT NULL CONSTRAINT ck_quests_token_budget CHECK (token_budget >= 0),
  spend_budget_usd numeric(12,4) NOT NULL CONSTRAINT ck_quests_spend_budget CHECK (spend_budget_usd >= 0),
  model_config     jsonb NOT NULL DEFAULT '{}'::jsonb,   -- per-phase-kind routing map (shape: ENTRY 6, R-061)
  process_config   jsonb NOT NULL DEFAULT '{}'::jsonb,   -- stop-rule/metabolism overlay (R-018, ENTRY 6)
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_quests_provenance_pair
    CHECK ((provenance_kind = 'fresh') = (source_quest_id IS NULL)),
  CONSTRAINT uq_quests_id_user UNIQUE (id, user_id),
  CONSTRAINT fk_quests_user FOREIGN KEY (user_id) REFERENCES users (id),
  CONSTRAINT fk_quests_source_quest
    FOREIGN KEY (source_quest_id, user_id) REFERENCES quests (id, user_id)
);

CREATE INDEX idx_quests_user_created ON quests (user_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- quest_sources — quest corpus membership (discovered mid-design, DR-18).
--   Sources are fetched-once-per-USER (D3/D6); a quest's corpus is the staged
--   set. The decompose gate (v_unmined_sources) reads THIS table, so agenda
--   exclusion lives in schema-owned SQL, not driver surgery (R-003, C43).
-- ---------------------------------------------------------------------------
CREATE TABLE quest_sources (
  quest_id   uuid NOT NULL,
  source_id  uuid NOT NULL,
  user_id    uuid NOT NULL,
  added_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pk_quest_sources PRIMARY KEY (quest_id, source_id),
  CONSTRAINT fk_quest_sources_quest
    FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_quest_sources_source
    FOREIGN KEY (source_id, user_id) REFERENCES sources (id, user_id)
);

CREATE INDEX idx_quest_sources_source ON quest_sources (source_id);

-- ---------------------------------------------------------------------------
-- chunk_strategies — chunking config rows (R-005). Global registry rows, not
--   tenant domain rows (DR-01 scope note): strategies are code-versioned
--   config identical for all users; re-chunk = new version row, old chunks
--   retained (chunks are never deleted in place).
-- ---------------------------------------------------------------------------
CREATE TABLE chunk_strategies (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name              text NOT NULL CONSTRAINT ck_chunk_strategies_name
                    CHECK (name ~ '^[a-z0-9][a-z0-9-]*$'),
  version           integer NOT NULL CONSTRAINT ck_chunk_strategies_version CHECK (version >= 1),
  target_chars      integer NOT NULL CONSTRAINT ck_chunk_strategies_target CHECK (target_chars > 0),
  overlap_chars     integer NOT NULL CONSTRAINT ck_chunk_strategies_overlap CHECK (overlap_chars >= 0),
  paragraph_aligned boolean NOT NULL,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_chunk_strategies_overlap_lt_target CHECK (overlap_chars < target_chars),
  CONSTRAINT uq_chunk_strategies_name_version UNIQUE (name, version)
);

-- ---------------------------------------------------------------------------
-- chunks — verbatim substrings of the snapshot blob with char offsets
--   (R-004, L1/L10: chunks derive from (blob, strategy); anchored against
--   the BLOB, never against another chunk). snapshot_char_count is a pinned
--   copy of sources.snapshot_char_count — the composite FK makes it
--   drift-proof and turns the offset bound into a write-time CHECK (DR-08).
--   Exact-substring proof against blob bytes is tool-time (constraint
--   catalog L1 row); bounds + length coherence are schema.
-- ---------------------------------------------------------------------------
CREATE TABLE chunks (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id           uuid NOT NULL,
  user_id             uuid NOT NULL,
  strategy_id         uuid NOT NULL,
  ordinal             integer NOT NULL CONSTRAINT ck_chunks_ordinal CHECK (ordinal >= 1),
  text                text NOT NULL CONSTRAINT ck_chunks_text_nonempty CHECK (char_length(text) > 0),
  char_start          integer NOT NULL CONSTRAINT ck_chunks_start CHECK (char_start >= 0),
  char_end            integer NOT NULL,
  snapshot_char_count integer NOT NULL CONSTRAINT ck_chunks_snapshot_chars CHECK (snapshot_char_count > 0),
  source_anchorable   boolean NOT NULL,  -- mirror of sources.anchorable; agenda sources ARE chunkable (R-003)
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_chunks_offsets CHECK (char_end > char_start),
  CONSTRAINT ck_chunks_span_bounded CHECK (char_end <= snapshot_char_count),
  CONSTRAINT ck_chunks_len_coherent CHECK (char_length(text) = char_end - char_start),
  CONSTRAINT uq_chunks_source_strategy_ordinal UNIQUE (source_id, strategy_id, ordinal),
  CONSTRAINT fk_chunks_source
    FOREIGN KEY (source_id, user_id, source_anchorable, snapshot_char_count)
    REFERENCES sources (id, user_id, anchorable, snapshot_char_count),
  CONSTRAINT fk_chunks_strategy FOREIGN KEY (strategy_id) REFERENCES chunk_strategies (id)
);

CREATE INDEX idx_chunks_strategy ON chunks (strategy_id);

-- ---------------------------------------------------------------------------
-- phases — quest process steps (R-012). round_no counts re-entries (the
--   frontier-build re-entry law, L4/muse); attempt_no counts wall/retry
--   attempts within a round. frontier_open / frontier_mass are the boundary
--   snapshots (R-009 per-phase mass persistence — I20 shadow instrumentation
--   made structural); written by the phase runner (ENTRY 6), never deleted.
-- ---------------------------------------------------------------------------
CREATE TABLE phases (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL,
  quest_id       uuid NOT NULL,
  kind           text NOT NULL CONSTRAINT ck_phases_kind
                 CHECK (kind IN ('decompose', 'frontier-build', 'descent', 'synthesis', 'verification')),
  round_no       integer NOT NULL DEFAULT 1 CONSTRAINT ck_phases_round CHECK (round_no >= 1),
  attempt_no     integer NOT NULL DEFAULT 1 CONSTRAINT ck_phases_attempt CHECK (attempt_no >= 1),
  state          text NOT NULL DEFAULT 'pending' CONSTRAINT ck_phases_state
                 CHECK (state IN ('pending', 'running', 'complete', 'failed')),
  started_at     timestamptz,
  ended_at       timestamptz,
  wall_timeout_s integer CONSTRAINT ck_phases_wall CHECK (wall_timeout_s IS NULL OR wall_timeout_s > 0),
  result         jsonb,
  frontier_open  integer CONSTRAINT ck_phases_frontier_open CHECK (frontier_open IS NULL OR frontier_open >= 0),
  frontier_mass  integer CONSTRAINT ck_phases_frontier_mass CHECK (frontier_mass IS NULL OR frontier_mass >= 0),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_phases_times CHECK (ended_at IS NULL OR (started_at IS NOT NULL AND ended_at >= started_at)),
  CONSTRAINT ck_phases_mass_pair CHECK ((frontier_open IS NULL) = (frontier_mass IS NULL)),
  CONSTRAINT ck_phases_snapshots_only_after_start
    CHECK (frontier_open IS NULL OR state IN ('complete', 'failed')),
  CONSTRAINT uq_phases_quest_kind_round_attempt UNIQUE (quest_id, kind, round_no, attempt_no),
  CONSTRAINT uq_phases_id_quest UNIQUE (id, quest_id),
  CONSTRAINT fk_phases_quest FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id)
);

-- ---------------------------------------------------------------------------
-- sessions — one agent run inside one phase attempt (R-013, L13, D5).
--   phase_id NOT NULL: the usage chain session→phase→quest→user (D10) is
--   total — initiation work runs as decompose round 1 (DR-13).
--   transcript_blob_key points at the verbatim session log in object
--   storage; tool_calls rows are the queryable audit (L8).
-- ---------------------------------------------------------------------------
CREATE TABLE sessions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid NOT NULL,
  quest_id            uuid NOT NULL,
  phase_id            uuid NOT NULL,
  mode                text NOT NULL CONSTRAINT ck_sessions_mode
                      CHECK (mode IN ('autonomous', 'interactive')),
  driver              text NOT NULL CONSTRAINT ck_sessions_driver
                      CHECK (driver IN ('orchestrator', 'operator')),
  model               text NOT NULL CONSTRAINT ck_sessions_model_nonempty
                      CHECK (char_length(btrim(model)) > 0),
  transcript_blob_key text CONSTRAINT ck_sessions_transcript_key
                      CHECK (transcript_blob_key ~ '^sessions/[0-9a-f-]{36}/transcript\.jsonl$'),
  started_at          timestamptz NOT NULL DEFAULT now(),
  ended_at            timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_sessions_times CHECK (ended_at IS NULL OR ended_at >= started_at),
  CONSTRAINT uq_sessions_id_quest UNIQUE (id, quest_id),
  CONSTRAINT uq_sessions_id_phase UNIQUE (id, phase_id),
  CONSTRAINT fk_sessions_quest FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_sessions_phase FOREIGN KEY (phase_id, quest_id) REFERENCES phases (id, quest_id)
);

CREATE INDEX idx_sessions_quest_started ON sessions (quest_id, started_at DESC);

-- ---------------------------------------------------------------------------
-- claims — K-nodes (R-006). Quest-scoped (D3 hermetic build unit).
--   canonical_text is GENERATED with the PoC normalization (NFC + collapse
--   ASCII-whitespace runs + ASCII strip — claim-graph-schema.json "canonical"
--   block, byte-for-byte semantics) so every writer is honest by
--   construction (DR-05). UNIQUE (quest_id, canonical_text) is the PoC
--   unique_per_label dedup guard at quest scope; cross-quest dedup is the
--   hub (ENTRY 2). quest_seq is the per-quest ordinal that K-aliases and the
--   frontier ordering tiebreak are derived from (DR-15).
-- ---------------------------------------------------------------------------
CREATE TABLE claims (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid NOT NULL,
  quest_id           uuid NOT NULL,
  quest_seq          integer NOT NULL CONSTRAINT ck_claims_seq CHECK (quest_seq >= 1),
  text               text NOT NULL CONSTRAINT ck_claims_text_nonempty
                     CHECK (char_length(btrim(text, ' ' || chr(9) || chr(10) || chr(13) || chr(11) || chr(12))) > 0),
  canonical_text     text GENERATED ALWAYS AS (
                       btrim(
                         regexp_replace(normalize(text, NFC), '[ \t\n\r\f\v]+', ' ', 'g'),
                         ' ' || chr(9) || chr(10) || chr(13) || chr(11) || chr(12)
                       )
                     ) STORED,
  terminal_type      text CONSTRAINT ck_claims_terminal_type
                     CHECK (terminal_type IN ('definitional-mathematical', 'primary-empirical', 'residual-uncertainty')),
  terminal_basis     text,
  urn                text NOT NULL CONSTRAINT ck_claims_urn_format
                     CHECK (urn ~ '^kb:claim:[1-9A-HJ-NP-Za-km-z]{10}$'),
  origin_quest_id    uuid,  -- non-NULL ⇒ grafted from another quest (R-021 stamps; semantics ENTRY 2)
  created_session_id uuid,  -- return address: which session coined this (BRIEF §2)
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_claims_terminal_pair
    CHECK ((terminal_type IS NULL) = (terminal_basis IS NULL)),
  CONSTRAINT ck_claims_terminal_basis_nonempty
    CHECK (terminal_basis IS NULL OR char_length(btrim(terminal_basis)) > 0),
  -- PoC exclude [["terminal","derives_from"]] is cross-table → tool-time +
  -- phase-gate (DR-09); the schema carries the terminal pairing laws above.
  CONSTRAINT uq_claims_quest_canonical UNIQUE (quest_id, canonical_text),
  CONSTRAINT uq_claims_quest_seq UNIQUE (quest_id, quest_seq),
  CONSTRAINT uq_claims_quest_urn UNIQUE (quest_id, urn),
  CONSTRAINT uq_claims_id_quest UNIQUE (id, quest_id),
  CONSTRAINT fk_claims_quest FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_claims_origin_quest
    FOREIGN KEY (origin_quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_claims_created_session
    FOREIGN KEY (created_session_id, quest_id) REFERENCES sessions (id, quest_id)
);

CREATE INDEX idx_claims_origin ON claims (origin_quest_id);

-- ---------------------------------------------------------------------------
-- evidence — E-nodes (R-007, L1). Verbatim span against the SNAPSHOT blob.
--   Schema carries: citable-only anchoring (conditional FK via
--   source_anchorable, DR-07), offset bounds + length coherence against a
--   pinned snapshot_char_count (DR-08), per-quest duplicate-span refusal
--   (PoC "duplicate-evidence-span" class). Byte-exact substring equality
--   against blob bytes is tool-time (L1 primary enforcement point).
-- ---------------------------------------------------------------------------
CREATE TABLE evidence (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid NOT NULL,
  quest_id            uuid NOT NULL,
  source_id           uuid NOT NULL,
  source_anchorable   boolean NOT NULL CONSTRAINT ck_evidence_citable CHECK (source_anchorable),
  snapshot_char_count integer NOT NULL CONSTRAINT ck_evidence_snapshot_chars CHECK (snapshot_char_count > 0),
  span_start          integer NOT NULL CONSTRAINT ck_evidence_span_start CHECK (span_start >= 0),
  span_end            integer NOT NULL,
  span_text           text NOT NULL CONSTRAINT ck_evidence_span_nonempty CHECK (char_length(span_text) > 0),
  reading             text NOT NULL CONSTRAINT ck_evidence_reading_nonempty
                      CHECK (char_length(btrim(reading)) > 0),
  created_session_id  uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_evidence_span_order CHECK (span_end > span_start),
  CONSTRAINT ck_evidence_span_bounded CHECK (span_end <= snapshot_char_count),
  CONSTRAINT ck_evidence_span_len CHECK (char_length(span_text) = span_end - span_start),
  CONSTRAINT uq_evidence_quest_span UNIQUE (quest_id, source_id, span_start, span_end),
  CONSTRAINT uq_evidence_id_quest UNIQUE (id, quest_id),
  CONSTRAINT fk_evidence_quest FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_evidence_source
    FOREIGN KEY (source_id, user_id, source_anchorable, snapshot_char_count)
    REFERENCES sources (id, user_id, anchorable, snapshot_char_count),
  CONSTRAINT fk_evidence_created_session
    FOREIGN KEY (created_session_id, quest_id) REFERENCES sessions (id, quest_id)
);

CREATE INDEX idx_evidence_source ON evidence (source_id);
CREATE INDEX idx_evidence_quest ON evidence (quest_id);

-- ---------------------------------------------------------------------------
-- evidence_edges — supports / contradicts, evidence→claim, ordered (R-008).
--   Ordered per (evidence, relation): position 1..n mirrors the PoC
--   edge_out arrays. edge_min (≥1 supports/contradicts per evidence) is
--   enforced by the fused atomic creation op (L5) — tool-time (DR-09).
-- ---------------------------------------------------------------------------
CREATE TABLE evidence_edges (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL,
  quest_id    uuid NOT NULL,
  evidence_id uuid NOT NULL,
  relation    text NOT NULL CONSTRAINT ck_evidence_edges_relation
              CHECK (relation IN ('supports', 'contradicts')),
  claim_id    uuid NOT NULL,
  position    integer NOT NULL CONSTRAINT ck_evidence_edges_position CHECK (position >= 1),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_evidence_edges_positions UNIQUE (evidence_id, relation, position),
  CONSTRAINT fk_evidence_edges_quest FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_evidence_edges_evidence
    FOREIGN KEY (evidence_id, quest_id) REFERENCES evidence (id, quest_id),
  CONSTRAINT fk_evidence_edges_claim
    FOREIGN KEY (claim_id, quest_id) REFERENCES claims (id, quest_id)
);

CREATE INDEX idx_evidence_edges_claim ON evidence_edges (claim_id, relation);

-- ---------------------------------------------------------------------------
-- claim_derivations — derives_from, claim→claim, ordered (R-008, L2).
--   claim_id is the deriving claim; parent_claim_id is what it derives from.
-- ---------------------------------------------------------------------------
CREATE TABLE claim_derivations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL,
  quest_id        uuid NOT NULL,
  claim_id        uuid NOT NULL,
  parent_claim_id uuid NOT NULL,
  position        integer NOT NULL CONSTRAINT ck_claim_derivations_position CHECK (position >= 1),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_claim_derivations_no_self CHECK (claim_id <> parent_claim_id),
  CONSTRAINT uq_claim_derivations_positions UNIQUE (claim_id, position),
  CONSTRAINT fk_claim_derivations_quest FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_claim_derivations_claim
    FOREIGN KEY (claim_id, quest_id) REFERENCES claims (id, quest_id),
  CONSTRAINT fk_claim_derivations_parent
    FOREIGN KEY (parent_claim_id, quest_id) REFERENCES claims (id, quest_id)
);

CREATE INDEX idx_claim_derivations_parent ON claim_derivations (parent_claim_id);

-- ---------------------------------------------------------------------------
-- frontier_entries — the scored work queue (R-009, L4, L15).
--   mass = uncertainty × relevance (integers 1..5 each). History retained:
--   closed entries are never deleted. DISTINCT-NEEDS law is schema
--   (uq_frontier_need — duplicate need strings corrupt mass ranking;
--   arc-run-20261121T §1 class f/(i). One OPEN entry per claim is a partial
--   unique index (PoC "frontier entry already exists for K<n>" refusal,
--   class f). Ordering law lives in v_frontier_open (schema-owned SQL).
-- ---------------------------------------------------------------------------
CREATE TABLE frontier_entries (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid NOT NULL,
  quest_id            uuid NOT NULL,
  claim_id            uuid NOT NULL,
  need                text NOT NULL CONSTRAINT ck_frontier_need_nonempty
                      CHECK (char_length(btrim(need)) > 0),
  uncertainty         integer NOT NULL CONSTRAINT ck_frontier_uncertainty
                      CHECK (uncertainty BETWEEN 1 AND 5),
  relevance           integer NOT NULL CONSTRAINT ck_frontier_relevance
                      CHECK (relevance BETWEEN 1 AND 5),
  state               text NOT NULL DEFAULT 'open' CONSTRAINT ck_frontier_state
                      CHECK (state IN ('open', 'closed')),
  spawned_by_phase_id uuid NOT NULL,
  closed_at           timestamptz,
  closure_type        text CONSTRAINT ck_frontier_closure_type
                      CHECK (closure_type IN ('fetch', 'internal', 'refusal')),
  opened_at           timestamptz NOT NULL DEFAULT now(),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_frontier_closure_pair
    CHECK ((state = 'open' AND closed_at IS NULL AND closure_type IS NULL)
        OR (state = 'closed' AND closed_at IS NOT NULL AND closure_type IS NOT NULL)),
  CONSTRAINT uq_frontier_need UNIQUE (quest_id, need),
  CONSTRAINT fk_frontier_quest FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_frontier_claim
    FOREIGN KEY (claim_id, quest_id) REFERENCES claims (id, quest_id),
  CONSTRAINT fk_frontier_spawned_phase
    FOREIGN KEY (spawned_by_phase_id, quest_id) REFERENCES phases (id, quest_id)
);

-- one OPEN entry per claim (re-posing a currently-open claim is refused);
-- closed history does not block future re-entry rounds
CREATE UNIQUE INDEX uq_frontier_open_per_claim ON frontier_entries (quest_id, claim_id)
  WHERE state = 'open';

-- listing-order index matching v_frontier_open's ORDER BY
CREATE INDEX idx_frontier_open_order
  ON frontier_entries (quest_id, (uncertainty * relevance) DESC, claim_id)
  WHERE state = 'open';

CREATE INDEX idx_frontier_claim ON frontier_entries (claim_id);

-- ---------------------------------------------------------------------------
-- conflicts — detected divergences (R-010; adjudication workflow ENTRY 7).
--   ≥2 distinct sources per conflict is BY CONSTRUCTION in the detector and
--   floored tool-time (DR-17); the junction keeps FK integrity and
--   distinctness (UNIQUE), and agenda sources are refused by the same
--   citable-only conditional FK as evidence (R-003 "never ... citable").
-- ---------------------------------------------------------------------------
CREATE TABLE conflicts (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid NOT NULL,
  quest_id              uuid NOT NULL,
  claim_id              uuid NOT NULL,
  divergence            text NOT NULL CONSTRAINT ck_conflicts_divergence_nonempty
                        CHECK (char_length(btrim(divergence)) > 0),
  resolution_hypothesis text,
  created_session_id    uuid,
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_conflicts_hypothesis_nonempty
    CHECK (resolution_hypothesis IS NULL OR char_length(btrim(resolution_hypothesis)) > 0),
  CONSTRAINT fk_conflicts_quest FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_conflicts_claim
    FOREIGN KEY (claim_id, quest_id) REFERENCES claims (id, quest_id),
  CONSTRAINT fk_conflicts_created_session
    FOREIGN KEY (created_session_id, quest_id) REFERENCES sessions (id, quest_id)
);

CREATE TABLE conflict_sources (
  conflict_id        uuid NOT NULL,
  source_id          uuid NOT NULL,
  user_id            uuid NOT NULL,
  source_anchorable  boolean NOT NULL CONSTRAINT ck_conflict_sources_citable CHECK (source_anchorable),
  CONSTRAINT pk_conflict_sources PRIMARY KEY (conflict_id, source_id),
  CONSTRAINT fk_conflict_sources_conflict FOREIGN KEY (conflict_id) REFERENCES conflicts (id) ON DELETE CASCADE,
  CONSTRAINT fk_conflict_sources_source
    FOREIGN KEY (source_id, user_id, source_anchorable)
    REFERENCES sources (id, user_id, anchorable)
);

-- ---------------------------------------------------------------------------
-- tool_calls — verbatim transcript audit (R-013, L8). One row per tool call,
--   args/result verbatim JSON, per-session ordering. Refused calls are
--   recorded with ok=false + error_class (the PoC refusal census pattern).
-- ---------------------------------------------------------------------------
CREATE TABLE tool_calls (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL,
  quest_id    uuid NOT NULL,
  session_id  uuid NOT NULL,
  seq         integer NOT NULL CONSTRAINT ck_tool_calls_seq CHECK (seq >= 1),
  tool        text NOT NULL CONSTRAINT ck_tool_calls_tool_nonempty
              CHECK (char_length(btrim(tool)) > 0),
  op          text,
  args        jsonb NOT NULL,
  result      jsonb NOT NULL,
  ok          boolean NOT NULL,
  error_class text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_tool_calls_error_shape
    CHECK ((ok AND error_class IS NULL) OR (NOT ok AND error_class IS NOT NULL)),
  CONSTRAINT uq_tool_calls_session_seq UNIQUE (session_id, seq),
  CONSTRAINT fk_tool_calls_quest FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_tool_calls_session
    FOREIGN KEY (session_id, quest_id) REFERENCES sessions (id, quest_id)
);

CREATE INDEX idx_tool_calls_quest ON tool_calls (quest_id, created_at DESC);
CREATE INDEX idx_tool_calls_session ON tool_calls (session_id);

-- ---------------------------------------------------------------------------
-- usage_events — the spend ledger (R-014, D10). One row per LLM/embedding
--   API call (granularity DR-14); chain session→phase→quest→user pinned by
--   composite FKs; cost_usd nullable for local models.
-- ---------------------------------------------------------------------------
CREATE TABLE usage_events (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL,
  quest_id      uuid NOT NULL,
  phase_id      uuid NOT NULL,
  session_id    uuid NOT NULL,
  kind          text NOT NULL CONSTRAINT ck_usage_kind CHECK (kind IN ('llm', 'embedding')),
  model         text NOT NULL CONSTRAINT ck_usage_model_nonempty
                CHECK (char_length(btrim(model)) > 0),
  input_tokens  integer NOT NULL CONSTRAINT ck_usage_input CHECK (input_tokens >= 0),
  output_tokens integer NOT NULL CONSTRAINT ck_usage_output CHECK (output_tokens >= 0),
  -- AMENDED 2026-11-22 (I04 DR-12, operator ruling "a amend as proposed"):
  -- provider-token detail columns. Providers differ in which keys they
  -- return (the fast-completions dialect system exists for exactly that)
  -- so all four default 0/NULL and the dialect layer fills what the
  -- provider actually returns; absent keys stay default.
  cache_read_tokens  integer NOT NULL DEFAULT 0 CONSTRAINT ck_usage_cache_read
                     CHECK (cache_read_tokens >= 0),
  cache_write_tokens integer NOT NULL DEFAULT 0 CONSTRAINT ck_usage_cache_write
                     CHECK (cache_write_tokens >= 0),
  reasoning_tokens  integer NOT NULL DEFAULT 0 CONSTRAINT ck_usage_reasoning
                     CHECK (reasoning_tokens >= 0),
  seed              integer CONSTRAINT ck_usage_seed CHECK (seed IS NULL OR seed >= 0),
  cost_usd      numeric(12,6) CONSTRAINT ck_usage_cost CHECK (cost_usd IS NULL OR cost_usd >= 0),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_usage_user FOREIGN KEY (user_id) REFERENCES users (id),
  CONSTRAINT fk_usage_quest FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_usage_phase FOREIGN KEY (phase_id, quest_id) REFERENCES phases (id, quest_id),
  CONSTRAINT fk_usage_session FOREIGN KEY (session_id, phase_id) REFERENCES sessions (id, phase_id)
);

CREATE INDEX idx_usage_quest ON usage_events (quest_id, created_at DESC);
CREATE INDEX idx_usage_user ON usage_events (user_id, created_at DESC);
CREATE INDEX idx_usage_session ON usage_events (session_id);

-- ============================================================================
-- Schema-owned query surface (gates and the agent status view read the SAME
-- SQL — L6 status parity: no asymmetric validators).
-- ============================================================================

-- Decompose gate input: a quest's staged CITABLE sources with no evidence
-- anchored in that quest yet. Agenda exclusion is in this SQL (R-003:
-- "excluded from the decompose gate by schema, not surgery" — C43 lesson).
CREATE VIEW v_unmined_sources AS
SELECT qs.quest_id,
       qs.source_id,
       s.urn,
       s.title
FROM quest_sources qs
JOIN sources s ON s.id = qs.source_id AND s.user_id = qs.user_id
WHERE s.role = 'citable'
  AND NOT EXISTS (
    SELECT 1 FROM evidence e
    WHERE e.source_id = qs.source_id AND e.quest_id = qs.quest_id
  );

CREATE VIEW v_decompose_remaining AS
SELECT quest_id,
       count(*) AS unmined_citable
FROM v_unmined_sources
GROUP BY quest_id;

-- Frontier work queue in the PoC's principled order:
-- uncertainty*relevance DESC, claim ASC (claim = per-quest K-ordinal), then
-- entry id as final tiebreak (L15). Listing caps are applied by callers
-- (tool layer, ENTRY 5); ordering is owned here.
CREATE VIEW v_frontier_open AS
SELECT f.quest_id,
       f.id        AS entry_id,
       f.claim_id,
       c.quest_seq AS claim_seq,
       f.need,
       f.uncertainty,
       f.relevance,
       f.uncertainty * f.relevance AS mass,
       f.spawned_by_phase_id,
       f.opened_at
FROM frontier_entries f
JOIN claims c ON c.id = f.claim_id AND c.quest_id = f.quest_id
WHERE f.state = 'open'
ORDER BY f.quest_id, (f.uncertainty * f.relevance) DESC, c.quest_seq ASC, f.id ASC;

-- L4 mass as a queryable number (phase boundaries persist a snapshot of
-- this into phases.frontier_mass / frontier_open).
CREATE VIEW v_frontier_mass AS
SELECT quest_id,
       count(*)             AS open_entries,
       coalesce(sum(mass), 0) AS mass
FROM v_frontier_open
GROUP BY quest_id;

-- L6 closure contract, one view for BOTH the agent status surface and the
-- phase gate: a claim is satisfied iff terminal ∨ derives_from ∨ open
-- frontier (PoC closure satisfy_one); bare claims are closure violations.
CREATE VIEW v_claim_closure AS
SELECT c.quest_id,
       c.id           AS claim_id,
       c.quest_seq,
       c.canonical_text,
       (c.terminal_type IS NOT NULL)                     AS has_terminal,
       c.terminal_type,
       (SELECT count(*) FROM claim_derivations d WHERE d.claim_id = c.id)   AS derives_from_count,
       (SELECT count(*) FROM evidence_edges ee WHERE ee.claim_id = c.id)    AS evidence_count,
       (SELECT count(*) FROM frontier_entries f
         WHERE f.claim_id = c.id AND f.state = 'open')                      AS open_frontier_count,
       ((c.terminal_type IS NULL)
         AND NOT EXISTS (SELECT 1 FROM claim_derivations d WHERE d.claim_id = c.id)
         AND NOT EXISTS (SELECT 1 FROM frontier_entries f
                          WHERE f.claim_id = c.id AND f.state = 'open'))    AS bare
FROM claims c;
