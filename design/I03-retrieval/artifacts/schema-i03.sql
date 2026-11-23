-- ============================================================================
-- kquest I03 retrieval — additive DDL (schema-i03.sql)
-- ----------------------------------------------------------------------------
-- Scope: the retrieval subsystem per design/I03-retrieval/DESIGN.md (D4).
--   - embedding_models: the model REGISTRY (R-028). Registry rows are global
--     config (no user_id — the I01 DR-01 chunk_strategies posture); the
--     registry is the ONLY model path: no kquest query or job names a model
--     by string (D4); the sanctioned exception is the GENERATED per-model
--     table name itself.
--   - embed_jobs: the fetch->chunk->embed pipeline ledger (R-031) —
--     idempotent (idem_key), resumable (done_items cursor), progress-tracked
--     (total/done), cost-accounted (usage_event link into the I01 ledger,
--     D10: embedding spend is real spend).
--   - Generated per-model pgvector tables (R-029): the TEMPLATE below is the
--     generator's contract; two concrete instantiations ship as fixtures
--     (emb_bge_m3_1024 vector(1024), emb_minilm_ab_384 vector(384)), each
--     with an hnsw (vector_cosine_ops) index.
--   - FTS substrate for the lexical leg (R-032): chunks.search_tsv, a
--     GENERATED tsvector column + GIN index (L10: derived from chunk text,
--     cannot drift).
--
-- Frozen-law touches (READ-ONLY files untouched; DR-15 pattern from I02):
--   additive UNIQUE keys on chunks/claims/frontier_entries/usage_events
--   (composite-FK targets for target-tenancy and usage-tenancy pins) and
--   the generated search_tsv column on chunks. Nothing removed, no column
--   semantics changed (DESIGN §3.4, DR-11).
--
-- Conventions as I01/I02: uuid ids, text+CHECK enums, timestamptz UTC,
-- named constraints (ck_/fk_/uq_) checkable against check-constraints.sh.
-- Runs clean on a fresh scratch database with the pgvector extension
-- (verified available: pgvector 0.8.7 — check-ddl.sh records the version,
-- discharging R-035).
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS vector;

-- ---------------------------------------------------------------------------
-- Additive keys on frozen I01 tables (composite-FK targets; strictly
--   additive indexes, no semantics changed — I02 DR-15 precedent).
--   uq_chunks_id_user / uq_claims_id_user / uq_frontier_id_user: let every
--   generated-table row pin its TARGET's tenancy (a cross-user vector row
--   is structurally impossible — probe E13). uq_usage_events_id_user: lets
--   embed_jobs pin its usage row's tenancy (probe E18).
--   NOTE: I02 DR-15 anticipated exactly this class of addition (it dropped
--   claims (id, user_id) as then-unneeded; I03 needs it — DR-11 records it).
-- ---------------------------------------------------------------------------
ALTER TABLE chunks          ADD CONSTRAINT uq_chunks_id_user          UNIQUE (id, user_id);
ALTER TABLE claims          ADD CONSTRAINT uq_claims_id_user          UNIQUE (id, user_id);
ALTER TABLE frontier_entries ADD CONSTRAINT uq_frontier_id_user       UNIQUE (id, user_id);
ALTER TABLE usage_events    ADD CONSTRAINT uq_usage_events_id_user    UNIQUE (id, user_id);

-- FTS substrate (R-032 lexical leg, DR-11): tsvector derived from the chunk
--   text. GENERATED = no writer can drift it (L10); GIN serves the tsquery
--   leg. English config is the day-one default (fixture corpus is English).
ALTER TABLE chunks ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (to_tsvector('english'::regconfig, text)) STORED;

CREATE INDEX idx_chunks_search_tsv ON chunks USING gin (search_tsv);

-- ---------------------------------------------------------------------------
-- embedding_models — the REGISTRY (R-028, D4)
--   One row per model DEPLOYMENT: wire_name+provider is the deployment
--   identity; slug feeds the generated table name (emb_<slug, _ for ->);
--   dimensions + metric are pinned at registration and baked into the
--   generated table's column type and hnsw opclass (the generator's
--   contract, DESIGN §4). batch_max_texts / input_max_chars parameterize the
--   fast-embeddings wire calls (R-034 batch discipline; DR-07).
--   Lifecycle: 'active' | 'retired' (DR-04). Retire means GONE: jobs
--   drained, generated table dropped, then the flip — the composite FKs
--   from embed_jobs (model_id, model_status) and every generated table
--   REFUSE the flip while anything pins 'active' (probes E07/E08).
--   api_key_ref is a credential REFERENCE (name), never a secret (R-079
--   posture; the app layer resolves it — ENTRY 8).
-- ---------------------------------------------------------------------------
CREATE TABLE embedding_models (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug            text NOT NULL CONSTRAINT ck_embedding_models_slug
                  CHECK (slug ~ '^[a-z0-9][a-z0-9-]*$'),
  wire_name       text NOT NULL CONSTRAINT ck_embedding_models_wire_name
                  CHECK (char_length(btrim(wire_name)) > 0),
  provider        text NOT NULL CONSTRAINT ck_embedding_models_provider
                  CHECK (char_length(btrim(provider)) > 0),
  endpoint        text NOT NULL CONSTRAINT ck_embedding_models_endpoint
                  CHECK (endpoint ~ '^https?://'),
  api_key_ref     text,
  dimensions      integer NOT NULL CONSTRAINT ck_embedding_models_dims
                  -- pgvector ANN indexes cap at 2000 dims; registry refuses more
                  CHECK (dimensions BETWEEN 1 AND 2000),
  metric          text NOT NULL DEFAULT 'cosine' CONSTRAINT ck_embedding_models_metric
                  CHECK (metric IN ('cosine', 'ip', 'l2')),
  batch_max_texts integer NOT NULL DEFAULT 64 CONSTRAINT ck_embedding_models_batch
                  CHECK (batch_max_texts > 0),
  input_max_chars integer NOT NULL DEFAULT 8192 CONSTRAINT ck_embedding_models_input_chars
                  CHECK (input_max_chars > 0),
  status          text NOT NULL DEFAULT 'active' CONSTRAINT ck_embedding_models_status
                  CHECK (status IN ('active', 'retired')),
  retired_at      timestamptz,
  -- generated-table name: emb_<slug with - as _>; uniqueness = one table per
  -- model, ever (a re-registered slug must not collide with a live table)
  table_name      text NOT NULL CONSTRAINT ck_embedding_models_table_name
                  CHECK (table_name ~ '^emb_[a-z0-9_]+$'),
  registered_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_embedding_models_retire_pair
    CHECK ((status = 'retired') = (retired_at IS NOT NULL)),
  CONSTRAINT ck_embedding_models_slug_table
    CHECK (table_name = 'emb_' || replace(slug, '-', '_')),
  CONSTRAINT uq_embedding_models_slug UNIQUE (slug),
  CONSTRAINT uq_embedding_models_table_name UNIQUE (table_name),
  CONSTRAINT uq_embedding_models_provider_wire UNIQUE (provider, wire_name),
  -- composite-FK target for the 'active' status pin from embed_jobs and
  -- every generated table (the retire gate, DR-04)
  CONSTRAINT uq_embedding_models_id_status UNIQUE (id, status)
);

-- ---------------------------------------------------------------------------
-- embed_jobs — the fetch->chunk->embed pipeline ledger (R-031, D4, L10)
--   One row per pipeline run. Idempotent: idem_key is a CALLER-MINTED
--   deterministic scope key (e.g. 'embed:<model-uuid>:chunk:strategy:<sid>'
--   or 'chunk:<sid>:quest:<qid>'); exactly one non-failed row may ever hold
--   a given key (uq_embed_jobs_idem_active — a rerun is a no-op resume, not
--   a new row; failed attempts don't block the retry row, so failure and
--   its retry share a key legally — seed demonstrates both).
--   Resumable: done_items is the durable cursor (progress-tracked); a killed
--   'running' row stays running until resumed/reaped (I01 DR-12 reasoning).
--   Cost-accounted: usage_event_id links the job's embedding spend into the
--   I01 usage_events ledger (D10) with tenancy pinned; only completed embed
--   jobs carry spend (partial spend is reconciled at completion — DR-06).
--   Attribution: quest_id is the TRIGGERING quest (usage chain follows it);
--   claim/need embed jobs are quest-scoped by law (their targets are
--   quest-scoped); corpus-level backfills with NULL quest are legal rows,
--   and their usage attribution is the DR-06 flagged question (ENTRY 8).
-- ---------------------------------------------------------------------------
CREATE TABLE embed_jobs (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL,
  quest_id       uuid,            -- triggering quest; NULL = corpus-level backfill (DR-06)
  phase_id       uuid,            -- triggering phase, pinned to quest when present
  kind           text NOT NULL CONSTRAINT ck_embed_jobs_kind
                 CHECK (kind IN ('fetch', 'chunk', 'embed')),
  model_id       uuid,            -- set iff kind='embed' (registry-only path);
                                   -- plain FK: LEDGER HISTORY must survive a model's
                                   -- retire (the retire gate lives on the vector
                                   -- tables' status pins, not here — DESIGN §11 J-RET)
  target_kind    text,            -- set iff kind='embed'
                 CONSTRAINT ck_embed_jobs_target_kind
                 CHECK (target_kind IS NULL OR target_kind IN ('chunk', 'claim', 'frontier_need')),
  strategy_id    uuid,            -- set iff kind='chunk' (the generation being built)
  source_id      uuid,            -- optional scope narrowing (fetch/chunk)
  state          text NOT NULL DEFAULT 'pending' CONSTRAINT ck_embed_jobs_state
                 CHECK (state IN ('pending', 'running', 'complete', 'failed')),
  idem_key       text NOT NULL CONSTRAINT ck_embed_jobs_idem_key
                 CHECK (char_length(btrim(idem_key)) > 0),
  total_items    integer NOT NULL DEFAULT 0 CONSTRAINT ck_embed_jobs_total CHECK (total_items >= 0),
  done_items     integer NOT NULL DEFAULT 0 CONSTRAINT ck_embed_jobs_done CHECK (done_items >= 0),
  started_at     timestamptz,
  ended_at       timestamptz,
  error_note     text CONSTRAINT ck_embed_jobs_error_note
                 CHECK (error_note IS NULL OR char_length(btrim(error_note)) > 0),
  usage_event_id uuid,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_embed_jobs_times
    CHECK (ended_at IS NULL OR (started_at IS NOT NULL AND ended_at >= started_at)),
  -- progress law: cursor inside bounds; completion means the cursor reached
  -- the total and no error is attached (probe E04/E05)
  CONSTRAINT ck_embed_jobs_progress CHECK (done_items <= total_items),
  CONSTRAINT ck_embed_jobs_complete_terminal
    CHECK (state <> 'complete' OR (done_items = total_items AND error_note IS NULL)),
  -- lifecycle pairing: started iff left pending; ended iff terminal
  CONSTRAINT ck_embed_jobs_run_pair
    CHECK ((state IN ('running', 'complete', 'failed')) = (started_at IS NOT NULL)),
  CONSTRAINT ck_embed_jobs_end_pair
    CHECK ((state IN ('complete', 'failed')) = (ended_at IS NOT NULL)),
  -- failure is explained; success never carries an error (probe E06)
  CONSTRAINT ck_embed_jobs_error_pair
    CHECK ((state = 'failed') = (error_note IS NOT NULL)),
  -- shape pairing: embed jobs name a registry model and a target family;
  -- chunk jobs name a strategy; embed jobs MAY name one when scoping to a
  -- chunk generation (re-embed of a strategy's chunks) (probe E19)
  CONSTRAINT ck_embed_jobs_model_pair
    CHECK ((model_id IS NOT NULL) = (kind = 'embed')),
  CONSTRAINT ck_embed_jobs_target_pair
    CHECK ((target_kind IS NOT NULL) = (kind = 'embed')),
  CONSTRAINT ck_embed_jobs_strategy_required
    CHECK (kind <> 'chunk' OR strategy_id IS NOT NULL),
  CONSTRAINT ck_embed_jobs_strategy_scope
    CHECK (strategy_id IS NULL OR kind = 'chunk'
           OR (kind = 'embed' AND target_kind = 'chunk')),
  -- quest scoping: ALL embed jobs are quest-scoped (DR-06 ruled A at
  -- ratification 2026-11-22: per-quest spend attribution — corpus
  -- backfills run as explicit per-quest jobs, one job per (strategy,
  -- quest); claim/need targets are quest-scoped rows; probe E22)
  CONSTRAINT ck_embed_jobs_scope
    CHECK (kind <> 'embed' OR quest_id IS NOT NULL),
  -- spend law: usage links exist only on COMPLETED embed jobs (D10; the
  -- ledger records real spend, reconciled at completion — DR-06)
  CONSTRAINT ck_embed_jobs_usage_kind
    CHECK (usage_event_id IS NULL OR (kind = 'embed' AND state = 'complete')),
  -- J-SPEND, the completed=>spend direction (judge F1): a COMPLETED
  -- embed job must carry its spend link. ck_embed_jobs_usage_kind above
  -- enforces the reverse direction only; this closes the loop so cost
  -- accounting is schema law in BOTH directions (D10).
  CONSTRAINT ck_embed_jobs_complete_spend
    CHECK (kind <> 'embed' OR state <> 'complete' OR usage_event_id IS NOT NULL),
  CONSTRAINT uq_embed_jobs_id_user UNIQUE (id, user_id),
  CONSTRAINT uq_embed_jobs_id_quest UNIQUE (id, quest_id),
  -- the registry is the ONLY model path: FK to the registry (embedding a
  -- model not in the registry is refused, probe E01); the ACTIVE-only law
  -- for NEW jobs is catalog row J-RET (the pipeline admits jobs against
  -- active registry rows only — DESIGN §11; job rows are history and
  -- deliberately survive a retire)
  CONSTRAINT fk_embed_jobs_model
    FOREIGN KEY (model_id) REFERENCES embedding_models (id),
  CONSTRAINT fk_embed_jobs_user FOREIGN KEY (user_id) REFERENCES users (id),
  CONSTRAINT fk_embed_jobs_quest FOREIGN KEY (quest_id, user_id) REFERENCES quests (id, user_id),
  CONSTRAINT fk_embed_jobs_phase FOREIGN KEY (phase_id, quest_id) REFERENCES phases (id, quest_id),
  CONSTRAINT fk_embed_jobs_strategy FOREIGN KEY (strategy_id) REFERENCES chunk_strategies (id),
  CONSTRAINT fk_embed_jobs_source
    FOREIGN KEY (source_id, user_id) REFERENCES sources (id, user_id),
  CONSTRAINT fk_embed_jobs_usage
    FOREIGN KEY (usage_event_id, user_id) REFERENCES usage_events (id, user_id)
);

CREATE INDEX idx_embed_jobs_user_created ON embed_jobs (user_id, created_at DESC);
CREATE INDEX idx_embed_jobs_state ON embed_jobs (state) WHERE state IN ('pending', 'running');

-- idempotency: exactly one non-failed row per idem key, EVER (a rerun of a
-- completed scope is a no-op resume; failed attempts don't block the retry
-- row — the seeded j08(failed)/j07(complete) pair shares a key legally)
CREATE UNIQUE INDEX uq_embed_jobs_idem_active ON embed_jobs (idem_key)
  WHERE state <> 'failed';

-- ===========================================================================
-- GENERATED PER-MODEL TABLE — THE TEMPLATE (R-029; the generator contract)
-- ===========================================================================
-- The registrar emits EXACTLY the DDL below at registration, substituting:
--   <slug>        registry slug, '-' -> '_'
--   <model_uuid>  the registry row's id
--   <dims>        registry dimensions (1..2000)
--   <ops>         registry metric -> vector_cosine_ops | vector_ip_ops |
--                 vector_l2_ops
-- One row per (model, target): UNIQUE NULLS NOT DISTINCT (target_kind,
-- chunk_id, claim_id, need_id) — re-embed of the same target is an UPDATE
-- (idempotent replace), never a second row (probe E14; NULLS NOT DISTINCT is
-- REQUIRED: two of the three target columns are NULL on every row, and
-- default-NULLS-DISTINCT uniqueness would never collide). Every row pins:
--   - the model id (CHECK literal — rows cannot migrate between models)
--   - model_status='active' (the retire gate: retiring refuses while any
--     vector pins 'active' — probe E07)
--   - the producing job (cost accounting is total: every vector has a job)
--   - target tenancy via three conditional composite FKs (exactly one of
--     chunk_id/claim_id/need_id — probe E12/E13)
--   - embedded_text: the EXACT text sent over the wire (audit + rebuild
--     diff; seed self-verifies byte-match against the target — L10)
-- Generated-table names are the SANCTIONED model-name exception (D4): the
-- name is registry-derived data, never an inline model string in query
-- text. hnsw defaults m=16, ef_construction=64 (pgvector defaults; DR-16);
-- ef_search is a query-time setting (default 40), owned by the query seam.
--
-- CREATE TABLE emb_<slug> (
--   id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
--   model_id      uuid NOT NULL CONSTRAINT ck_emb_<slug>_model
--                 CHECK (model_id = '<model_uuid>'),
--   model_status  text NOT NULL CONSTRAINT ck_emb_<slug>_status
--                 CHECK (model_status = 'active'),
--   user_id       uuid NOT NULL,
--   target_kind   text NOT NULL CONSTRAINT ck_emb_<slug>_kind
--                 CHECK (target_kind IN ('chunk', 'claim', 'frontier_need')),
--   chunk_id      uuid,
--   claim_id      uuid,
--   need_id       uuid,
--   embedding     vector(<dims>) NOT NULL,
--   embedded_text text NOT NULL CONSTRAINT ck_emb_<slug>_text_nonempty
--                 CHECK (char_length(embedded_text) > 0),
--   job_id        uuid NOT NULL,
--   embedded_at   timestamptz NOT NULL DEFAULT now(),
--   CONSTRAINT ck_emb_<slug>_target_exactly_one
--     CHECK ((chunk_id IS NOT NULL)::int + (claim_id IS NOT NULL)::int
--            + (need_id IS NOT NULL)::int = 1),
--   CONSTRAINT ck_emb_<slug>_target_matches_kind
--     CHECK (target_kind = CASE WHEN chunk_id IS NOT NULL THEN 'chunk'
--                               WHEN claim_id IS NOT NULL THEN 'claim'
--                               ELSE 'frontier_need' END),
--   CONSTRAINT uq_emb_<slug>_target UNIQUE NULLS NOT DISTINCT (target_kind, chunk_id, claim_id, need_id),
--   CONSTRAINT uq_emb_<slug>_id_user UNIQUE (id, user_id),
--   CONSTRAINT fk_emb_<slug>_model
--     FOREIGN KEY (model_id, model_status) REFERENCES embedding_models (id, status),
--   CONSTRAINT fk_emb_<slug>_job
--     FOREIGN KEY (job_id, user_id) REFERENCES embed_jobs (id, user_id),
--   CONSTRAINT fk_emb_<slug>_chunk
--     FOREIGN KEY (chunk_id, user_id) REFERENCES chunks (id, user_id),
--   CONSTRAINT fk_emb_<slug>_claim
--     FOREIGN KEY (claim_id, user_id) REFERENCES claims (id, user_id),
--   CONSTRAINT fk_emb_<slug>_need
--     FOREIGN KEY (need_id, user_id) REFERENCES frontier_entries (id, user_id)
-- );
-- CREATE INDEX idx_emb_<slug>_hnsw ON emb_<slug> USING hnsw (embedding <ops>);
-- CREATE INDEX idx_emb_<slug>_job ON emb_<slug> (job_id);
-- CREATE INDEX idx_emb_<slug>_user ON emb_<slug> (user_id);
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Concrete generated table 1 — the fixture ACTIVE dense model
--   (bge-m3 via OpenRouter, 1024d cosine — the D4 first registration;
--   registry row seeded in seed-i03.sql with the matching fixed uuid).
--   Instantiated from the template above verbatim modulo substitution.
-- ---------------------------------------------------------------------------
CREATE TABLE emb_bge_m3_1024 (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_id      uuid NOT NULL CONSTRAINT ck_emb_bge_m3_1024_model
                CHECK (model_id = '92000000-0000-4000-8000-000000000001'),
  model_status  text NOT NULL CONSTRAINT ck_emb_bge_m3_1024_status
                CHECK (model_status = 'active'),
  user_id       uuid NOT NULL,
  target_kind   text NOT NULL CONSTRAINT ck_emb_bge_m3_1024_kind
                CHECK (target_kind IN ('chunk', 'claim', 'frontier_need')),
  chunk_id      uuid,
  claim_id      uuid,
  need_id       uuid,
  embedding     vector(1024) NOT NULL,
  embedded_text text NOT NULL CONSTRAINT ck_emb_bge_m3_1024_text_nonempty
                CHECK (char_length(embedded_text) > 0),
  job_id        uuid NOT NULL,
  embedded_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_emb_bge_m3_1024_target_exactly_one
    CHECK ((chunk_id IS NOT NULL)::int + (claim_id IS NOT NULL)::int
           + (need_id IS NOT NULL)::int = 1),
  CONSTRAINT ck_emb_bge_m3_1024_target_matches_kind
    CHECK (target_kind = CASE WHEN chunk_id IS NOT NULL THEN 'chunk'
                              WHEN claim_id IS NOT NULL THEN 'claim'
                              ELSE 'frontier_need' END),
  CONSTRAINT uq_emb_bge_m3_1024_target UNIQUE NULLS NOT DISTINCT (target_kind, chunk_id, claim_id, need_id),
  CONSTRAINT uq_emb_bge_m3_1024_id_user UNIQUE (id, user_id),
  CONSTRAINT fk_emb_bge_m3_1024_model
    FOREIGN KEY (model_id, model_status) REFERENCES embedding_models (id, status),
  CONSTRAINT fk_emb_bge_m3_1024_job
    FOREIGN KEY (job_id, user_id) REFERENCES embed_jobs (id, user_id),
  CONSTRAINT fk_emb_bge_m3_1024_chunk
    FOREIGN KEY (chunk_id, user_id) REFERENCES chunks (id, user_id),
  CONSTRAINT fk_emb_bge_m3_1024_claim
    FOREIGN KEY (claim_id, user_id) REFERENCES claims (id, user_id),
  CONSTRAINT fk_emb_bge_m3_1024_need
    FOREIGN KEY (need_id, user_id) REFERENCES frontier_entries (id, user_id)
);

CREATE INDEX idx_emb_bge_m3_1024_hnsw ON emb_bge_m3_1024
  USING hnsw (embedding vector_cosine_ops);
CREATE INDEX idx_emb_bge_m3_1024_job ON emb_bge_m3_1024 (job_id);
CREATE INDEX idx_emb_bge_m3_1024_user ON emb_bge_m3_1024 (user_id);

-- ---------------------------------------------------------------------------
-- Concrete generated table 2 — the fixture A/B CHALLENGER (active, 384d;
--   a different dims count proves dims are pinned per registration and the
--   same query family runs against any registered model by id — A/B is a
--   data operation, zero code change; queries-i03.sql family (a4)).
-- ---------------------------------------------------------------------------
CREATE TABLE emb_minilm_ab_384 (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_id      uuid NOT NULL CONSTRAINT ck_emb_minilm_ab_384_model
                CHECK (model_id = '92000000-0000-4000-8000-000000000002'),
  model_status  text NOT NULL CONSTRAINT ck_emb_minilm_ab_384_status
                CHECK (model_status = 'active'),
  user_id       uuid NOT NULL,
  target_kind   text NOT NULL CONSTRAINT ck_emb_minilm_ab_384_kind
                CHECK (target_kind IN ('chunk', 'claim', 'frontier_need')),
  chunk_id      uuid,
  claim_id      uuid,
  need_id       uuid,
  embedding     vector(384) NOT NULL,
  embedded_text text NOT NULL CONSTRAINT ck_emb_minilm_ab_384_text_nonempty
                CHECK (char_length(embedded_text) > 0),
  job_id        uuid NOT NULL,
  embedded_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_emb_minilm_ab_384_target_exactly_one
    CHECK ((chunk_id IS NOT NULL)::int + (claim_id IS NOT NULL)::int
           + (need_id IS NOT NULL)::int = 1),
  CONSTRAINT ck_emb_minilm_ab_384_target_matches_kind
    CHECK (target_kind = CASE WHEN chunk_id IS NOT NULL THEN 'chunk'
                              WHEN claim_id IS NOT NULL THEN 'claim'
                              ELSE 'frontier_need' END),
  CONSTRAINT uq_emb_minilm_ab_384_target UNIQUE NULLS NOT DISTINCT (target_kind, chunk_id, claim_id, need_id),
  CONSTRAINT uq_emb_minilm_ab_384_id_user UNIQUE (id, user_id),
  CONSTRAINT fk_emb_minilm_ab_384_model
    FOREIGN KEY (model_id, model_status) REFERENCES embedding_models (id, status),
  CONSTRAINT fk_emb_minilm_ab_384_job
    FOREIGN KEY (job_id, user_id) REFERENCES embed_jobs (id, user_id),
  CONSTRAINT fk_emb_minilm_ab_384_chunk
    FOREIGN KEY (chunk_id, user_id) REFERENCES chunks (id, user_id),
  CONSTRAINT fk_emb_minilm_ab_384_claim
    FOREIGN KEY (claim_id, user_id) REFERENCES claims (id, user_id),
  CONSTRAINT fk_emb_minilm_ab_384_need
    FOREIGN KEY (need_id, user_id) REFERENCES frontier_entries (id, user_id)
);

CREATE INDEX idx_emb_minilm_ab_384_hnsw ON emb_minilm_ab_384
  USING hnsw (embedding vector_cosine_ops);
CREATE INDEX idx_emb_minilm_ab_384_job ON emb_minilm_ab_384 (job_id);
CREATE INDEX idx_emb_minilm_ab_384_user ON emb_minilm_ab_384 (user_id);
