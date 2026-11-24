--
-- PostgreSQL database dump
--



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: chunk_strategies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chunk_strategies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    version integer NOT NULL,
    target_chars integer NOT NULL,
    overlap_chars integer NOT NULL,
    paragraph_aligned boolean NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_chunk_strategies_name CHECK ((name ~ '^[a-z0-9][a-z0-9-]*$'::text)),
    CONSTRAINT ck_chunk_strategies_overlap CHECK ((overlap_chars >= 0)),
    CONSTRAINT ck_chunk_strategies_overlap_lt_target CHECK ((overlap_chars < target_chars)),
    CONSTRAINT ck_chunk_strategies_target CHECK ((target_chars > 0)),
    CONSTRAINT ck_chunk_strategies_version CHECK ((version >= 1))
);


--
-- Name: chunks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chunks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_id uuid NOT NULL,
    user_id uuid NOT NULL,
    strategy_id uuid NOT NULL,
    ordinal integer NOT NULL,
    text text NOT NULL,
    char_start integer NOT NULL,
    char_end integer NOT NULL,
    snapshot_char_count integer NOT NULL,
    source_anchorable boolean NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, text)) STORED,
    CONSTRAINT ck_chunks_len_coherent CHECK ((char_length(text) = (char_end - char_start))),
    CONSTRAINT ck_chunks_offsets CHECK ((char_end > char_start)),
    CONSTRAINT ck_chunks_ordinal CHECK ((ordinal >= 1)),
    CONSTRAINT ck_chunks_snapshot_chars CHECK ((snapshot_char_count > 0)),
    CONSTRAINT ck_chunks_span_bounded CHECK ((char_end <= snapshot_char_count)),
    CONSTRAINT ck_chunks_start CHECK ((char_start >= 0)),
    CONSTRAINT ck_chunks_text_nonempty CHECK ((char_length(text) > 0))
);


--
-- Name: claim_derivations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.claim_derivations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    quest_id uuid NOT NULL,
    claim_id uuid NOT NULL,
    parent_claim_id uuid NOT NULL,
    "position" integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_claim_derivations_no_self CHECK ((claim_id <> parent_claim_id)),
    CONSTRAINT ck_claim_derivations_position CHECK (("position" >= 1))
);


--
-- Name: claims; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.claims (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    quest_id uuid NOT NULL,
    quest_seq integer NOT NULL,
    text text NOT NULL,
    canonical_text text GENERATED ALWAYS AS (btrim(regexp_replace(NORMALIZE(text, NFC), '[ \t\n\r\f\v]+'::text, ' '::text, 'g'::text), (((((' '::text || chr(9)) || chr(10)) || chr(13)) || chr(11)) || chr(12)))) STORED,
    terminal_type text,
    terminal_basis text,
    urn text NOT NULL,
    origin_quest_id uuid,
    created_session_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_claims_seq CHECK ((quest_seq >= 1)),
    CONSTRAINT ck_claims_terminal_basis_nonempty CHECK (((terminal_basis IS NULL) OR (char_length(btrim(terminal_basis)) > 0))),
    CONSTRAINT ck_claims_terminal_pair CHECK (((terminal_type IS NULL) = (terminal_basis IS NULL))),
    CONSTRAINT ck_claims_terminal_type CHECK ((terminal_type = ANY (ARRAY['definitional-mathematical'::text, 'primary-empirical'::text, 'residual-uncertainty'::text]))),
    CONSTRAINT ck_claims_text_nonempty CHECK ((char_length(btrim(text, (((((' '::text || chr(9)) || chr(10)) || chr(13)) || chr(11)) || chr(12)))) > 0)),
    CONSTRAINT ck_claims_urn_format CHECK ((urn ~ '^kb:claim:[1-9A-HJ-NP-Za-km-z]{10}$'::text))
);


--
-- Name: conflict_sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conflict_sources (
    conflict_id uuid NOT NULL,
    source_id uuid NOT NULL,
    user_id uuid NOT NULL,
    source_anchorable boolean NOT NULL,
    CONSTRAINT ck_conflict_sources_citable CHECK (source_anchorable)
);


--
-- Name: conflicts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conflicts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    quest_id uuid NOT NULL,
    claim_id uuid NOT NULL,
    divergence text NOT NULL,
    resolution_hypothesis text,
    created_session_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_conflicts_divergence_nonempty CHECK ((char_length(btrim(divergence)) > 0)),
    CONSTRAINT ck_conflicts_hypothesis_nonempty CHECK (((resolution_hypothesis IS NULL) OR (char_length(btrim(resolution_hypothesis)) > 0)))
);


--
-- Name: documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documents (
    id bigint NOT NULL,
    attachment_data text,
    byte_count bigint,
    created_at timestamp with time zone NOT NULL,
    processed_at timestamp with time zone,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: documents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.documents ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: emb_bge_m3_1024; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.emb_bge_m3_1024 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    model_id uuid NOT NULL,
    model_status text NOT NULL,
    user_id uuid NOT NULL,
    target_kind text NOT NULL,
    chunk_id uuid,
    claim_id uuid,
    need_id uuid,
    embedding public.vector(1024) NOT NULL,
    embedded_text text NOT NULL,
    job_id uuid NOT NULL,
    embedded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_emb_bge_m3_1024_kind CHECK ((target_kind = ANY (ARRAY['chunk'::text, 'claim'::text, 'frontier_need'::text]))),
    CONSTRAINT ck_emb_bge_m3_1024_model CHECK ((model_id = '92000000-0000-4000-8000-000000000001'::uuid)),
    CONSTRAINT ck_emb_bge_m3_1024_status CHECK ((model_status = 'active'::text)),
    CONSTRAINT ck_emb_bge_m3_1024_target_exactly_one CHECK ((((((chunk_id IS NOT NULL))::integer + ((claim_id IS NOT NULL))::integer) + ((need_id IS NOT NULL))::integer) = 1)),
    CONSTRAINT ck_emb_bge_m3_1024_target_matches_kind CHECK ((target_kind =
CASE
    WHEN (chunk_id IS NOT NULL) THEN 'chunk'::text
    WHEN (claim_id IS NOT NULL) THEN 'claim'::text
    ELSE 'frontier_need'::text
END)),
    CONSTRAINT ck_emb_bge_m3_1024_text_nonempty CHECK ((char_length(embedded_text) > 0))
);


--
-- Name: emb_minilm_ab_384; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.emb_minilm_ab_384 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    model_id uuid NOT NULL,
    model_status text NOT NULL,
    user_id uuid NOT NULL,
    target_kind text NOT NULL,
    chunk_id uuid,
    claim_id uuid,
    need_id uuid,
    embedding public.vector(384) NOT NULL,
    embedded_text text NOT NULL,
    job_id uuid NOT NULL,
    embedded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_emb_minilm_ab_384_kind CHECK ((target_kind = ANY (ARRAY['chunk'::text, 'claim'::text, 'frontier_need'::text]))),
    CONSTRAINT ck_emb_minilm_ab_384_model CHECK ((model_id = '92000000-0000-4000-8000-000000000002'::uuid)),
    CONSTRAINT ck_emb_minilm_ab_384_status CHECK ((model_status = 'active'::text)),
    CONSTRAINT ck_emb_minilm_ab_384_target_exactly_one CHECK ((((((chunk_id IS NOT NULL))::integer + ((claim_id IS NOT NULL))::integer) + ((need_id IS NOT NULL))::integer) = 1)),
    CONSTRAINT ck_emb_minilm_ab_384_target_matches_kind CHECK ((target_kind =
CASE
    WHEN (chunk_id IS NOT NULL) THEN 'chunk'::text
    WHEN (claim_id IS NOT NULL) THEN 'claim'::text
    ELSE 'frontier_need'::text
END)),
    CONSTRAINT ck_emb_minilm_ab_384_text_nonempty CHECK ((char_length(embedded_text) > 0))
);


--
-- Name: embed_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.embed_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    quest_id uuid,
    phase_id uuid,
    kind text NOT NULL,
    model_id uuid,
    target_kind text,
    strategy_id uuid,
    source_id uuid,
    state text DEFAULT 'pending'::text NOT NULL,
    idem_key text NOT NULL,
    total_items integer DEFAULT 0 NOT NULL,
    done_items integer DEFAULT 0 NOT NULL,
    started_at timestamp with time zone,
    ended_at timestamp with time zone,
    error_note text,
    usage_event_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_embed_jobs_complete_spend CHECK (((kind <> 'embed'::text) OR (state <> 'complete'::text) OR (usage_event_id IS NOT NULL))),
    CONSTRAINT ck_embed_jobs_complete_terminal CHECK (((state <> 'complete'::text) OR ((done_items = total_items) AND (error_note IS NULL)))),
    CONSTRAINT ck_embed_jobs_done CHECK ((done_items >= 0)),
    CONSTRAINT ck_embed_jobs_end_pair CHECK (((state = ANY (ARRAY['complete'::text, 'failed'::text])) = (ended_at IS NOT NULL))),
    CONSTRAINT ck_embed_jobs_error_note CHECK (((error_note IS NULL) OR (char_length(btrim(error_note)) > 0))),
    CONSTRAINT ck_embed_jobs_error_pair CHECK (((state = 'failed'::text) = (error_note IS NOT NULL))),
    CONSTRAINT ck_embed_jobs_idem_key CHECK ((char_length(btrim(idem_key)) > 0)),
    CONSTRAINT ck_embed_jobs_kind CHECK ((kind = ANY (ARRAY['fetch'::text, 'chunk'::text, 'embed'::text]))),
    CONSTRAINT ck_embed_jobs_model_pair CHECK (((model_id IS NOT NULL) = (kind = 'embed'::text))),
    CONSTRAINT ck_embed_jobs_progress CHECK ((done_items <= total_items)),
    CONSTRAINT ck_embed_jobs_run_pair CHECK (((state = ANY (ARRAY['running'::text, 'complete'::text, 'failed'::text])) = (started_at IS NOT NULL))),
    CONSTRAINT ck_embed_jobs_scope CHECK (((kind <> 'embed'::text) OR (quest_id IS NOT NULL))),
    CONSTRAINT ck_embed_jobs_state CHECK ((state = ANY (ARRAY['pending'::text, 'running'::text, 'complete'::text, 'failed'::text]))),
    CONSTRAINT ck_embed_jobs_strategy_required CHECK (((kind <> 'chunk'::text) OR (strategy_id IS NOT NULL))),
    CONSTRAINT ck_embed_jobs_strategy_scope CHECK (((strategy_id IS NULL) OR (kind = 'chunk'::text) OR ((kind = 'embed'::text) AND (target_kind = 'chunk'::text)))),
    CONSTRAINT ck_embed_jobs_target_kind CHECK (((target_kind IS NULL) OR (target_kind = ANY (ARRAY['chunk'::text, 'claim'::text, 'frontier_need'::text])))),
    CONSTRAINT ck_embed_jobs_target_pair CHECK (((target_kind IS NOT NULL) = (kind = 'embed'::text))),
    CONSTRAINT ck_embed_jobs_times CHECK (((ended_at IS NULL) OR ((started_at IS NOT NULL) AND (ended_at >= started_at)))),
    CONSTRAINT ck_embed_jobs_total CHECK ((total_items >= 0)),
    CONSTRAINT ck_embed_jobs_usage_kind CHECK (((usage_event_id IS NULL) OR ((kind = 'embed'::text) AND (state = 'complete'::text))))
);


--
-- Name: embedding_models; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.embedding_models (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug text NOT NULL,
    wire_name text NOT NULL,
    provider text NOT NULL,
    endpoint text NOT NULL,
    api_key_ref text,
    dimensions integer NOT NULL,
    metric text DEFAULT 'cosine'::text NOT NULL,
    batch_max_texts integer DEFAULT 64 NOT NULL,
    input_max_chars integer DEFAULT 8192 NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    retired_at timestamp with time zone,
    table_name text NOT NULL,
    registered_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_embedding_models_batch CHECK ((batch_max_texts > 0)),
    CONSTRAINT ck_embedding_models_dims CHECK (((dimensions >= 1) AND (dimensions <= 2000))),
    CONSTRAINT ck_embedding_models_endpoint CHECK ((endpoint ~ '^https?://'::text)),
    CONSTRAINT ck_embedding_models_input_chars CHECK ((input_max_chars > 0)),
    CONSTRAINT ck_embedding_models_metric CHECK ((metric = ANY (ARRAY['cosine'::text, 'ip'::text, 'l2'::text]))),
    CONSTRAINT ck_embedding_models_provider CHECK ((char_length(btrim(provider)) > 0)),
    CONSTRAINT ck_embedding_models_retire_pair CHECK (((status = 'retired'::text) = (retired_at IS NOT NULL))),
    CONSTRAINT ck_embedding_models_slug CHECK ((slug ~ '^[a-z0-9][a-z0-9-]*$'::text)),
    CONSTRAINT ck_embedding_models_slug_table CHECK ((table_name = ('emb_'::text || replace(slug, '-'::text, '_'::text)))),
    CONSTRAINT ck_embedding_models_status CHECK ((status = ANY (ARRAY['active'::text, 'retired'::text]))),
    CONSTRAINT ck_embedding_models_table_name CHECK ((table_name ~ '^emb_[a-z0-9_]+$'::text)),
    CONSTRAINT ck_embedding_models_wire_name CHECK ((char_length(btrim(wire_name)) > 0))
);


--
-- Name: evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.evidence (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    quest_id uuid NOT NULL,
    source_id uuid NOT NULL,
    source_anchorable boolean NOT NULL,
    snapshot_char_count integer NOT NULL,
    span_start integer NOT NULL,
    span_end integer NOT NULL,
    span_text text NOT NULL,
    reading text NOT NULL,
    created_session_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_evidence_citable CHECK (source_anchorable),
    CONSTRAINT ck_evidence_reading_nonempty CHECK ((char_length(btrim(reading)) > 0)),
    CONSTRAINT ck_evidence_snapshot_chars CHECK ((snapshot_char_count > 0)),
    CONSTRAINT ck_evidence_span_bounded CHECK ((span_end <= snapshot_char_count)),
    CONSTRAINT ck_evidence_span_len CHECK ((char_length(span_text) = (span_end - span_start))),
    CONSTRAINT ck_evidence_span_nonempty CHECK ((char_length(span_text) > 0)),
    CONSTRAINT ck_evidence_span_order CHECK ((span_end > span_start)),
    CONSTRAINT ck_evidence_span_start CHECK ((span_start >= 0))
);


--
-- Name: evidence_edges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.evidence_edges (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    quest_id uuid NOT NULL,
    evidence_id uuid NOT NULL,
    relation text NOT NULL,
    claim_id uuid NOT NULL,
    "position" integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_evidence_edges_position CHECK (("position" >= 1)),
    CONSTRAINT ck_evidence_edges_relation CHECK ((relation = ANY (ARRAY['supports'::text, 'contradicts'::text])))
);


--
-- Name: frontier_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.frontier_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    quest_id uuid NOT NULL,
    claim_id uuid NOT NULL,
    need text NOT NULL,
    uncertainty integer NOT NULL,
    relevance integer NOT NULL,
    state text DEFAULT 'open'::text NOT NULL,
    spawned_by_phase_id uuid NOT NULL,
    closed_at timestamp with time zone,
    closure_type text,
    opened_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_frontier_closure_pair CHECK ((((state = 'open'::text) AND (closed_at IS NULL) AND (closure_type IS NULL)) OR ((state = 'closed'::text) AND (closed_at IS NOT NULL) AND (closure_type IS NOT NULL)))),
    CONSTRAINT ck_frontier_closure_type CHECK ((closure_type = ANY (ARRAY['fetch'::text, 'internal'::text, 'refusal'::text]))),
    CONSTRAINT ck_frontier_need_nonempty CHECK ((char_length(btrim(need)) > 0)),
    CONSTRAINT ck_frontier_relevance CHECK (((relevance >= 1) AND (relevance <= 5))),
    CONSTRAINT ck_frontier_state CHECK ((state = ANY (ARRAY['open'::text, 'closed'::text]))),
    CONSTRAINT ck_frontier_uncertainty CHECK (((uncertainty >= 1) AND (uncertainty <= 5)))
);


--
-- Name: ladder_passes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ladder_passes (
    id uuid NOT NULL,
    model text NOT NULL,
    rung text NOT NULL,
    serving_stack text NOT NULL,
    passed_at timestamp with time zone NOT NULL,
    evidence_ref text NOT NULL,
    passed_by text NOT NULL,
    CONSTRAINT ladder_passes_rung_check CHECK ((rung = ANY (ARRAY['probe'::text, 'smoke'::text, 'partial'::text, 'full'::text])))
);


--
-- Name: phase_transitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.phase_transitions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ordinal integer NOT NULL,
    from_phase text NOT NULL,
    event text NOT NULL,
    guard text NOT NULL,
    to_phase text NOT NULL,
    phase_kind_exit text NOT NULL,
    evidence text NOT NULL,
    CONSTRAINT ck_phase_transitions_event CHECK ((event = ANY (ARRAY['phase_complete'::text, 'graph_invalid'::text, 'transcript_ceiling'::text, 'slow_stall_unattended'::text, 'retry_cap_exhausted'::text, 'budget_exhausted'::text, 'phase_cap'::text, 'verification_failed'::text]))),
    CONSTRAINT ck_phase_transitions_from_phase CHECK ((from_phase = ANY (ARRAY['briefing-init'::text, 'decompose'::text, 'frontier-build'::text, 'descent'::text, 'synthesis'::text, 'verification'::text, 'any-phase'::text, 'any-work-phase'::text, 'any-finisher-phase'::text]))),
    CONSTRAINT ck_phase_transitions_guard_nonempty CHECK ((char_length(btrim(guard)) > 0)),
    CONSTRAINT ck_phase_transitions_ordinal CHECK ((ordinal >= 1)),
    CONSTRAINT ck_phase_transitions_phase_kind_exit CHECK ((phase_kind_exit = ANY (ARRAY['autonomy-handoff'::text, 'counter-exit'::text, 'mass-floor-gate'::text, 'mass-decay-armed'::text, 'mass-decay-primary'::text, 'plateau-cut-backstop'::text, 'drained-exit'::text, 'descent-repeat'::text, 'citation-coverage-exit'::text, 'verification-terminal'::text, 'rework-pause'::text, 'route-to-synthesis'::text, 'pause-and-present'::text, 'stop-loud'::text]))),
    CONSTRAINT ck_phase_transitions_to_phase CHECK ((to_phase = ANY (ARRAY['decompose'::text, 'frontier-build'::text, 'descent'::text, 'synthesis'::text, 'verification'::text, 'quest-done'::text, 'paused'::text, 'stopped'::text])))
);


--
-- Name: phases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.phases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    quest_id uuid NOT NULL,
    kind text NOT NULL,
    round_no integer DEFAULT 1 NOT NULL,
    attempt_no integer DEFAULT 1 NOT NULL,
    state text DEFAULT 'pending'::text NOT NULL,
    started_at timestamp with time zone,
    ended_at timestamp with time zone,
    wall_timeout_s integer,
    result jsonb,
    frontier_open integer,
    frontier_mass integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_phases_attempt CHECK ((attempt_no >= 1)),
    CONSTRAINT ck_phases_frontier_mass CHECK (((frontier_mass IS NULL) OR (frontier_mass >= 0))),
    CONSTRAINT ck_phases_frontier_open CHECK (((frontier_open IS NULL) OR (frontier_open >= 0))),
    CONSTRAINT ck_phases_kind CHECK ((kind = ANY (ARRAY['decompose'::text, 'frontier-build'::text, 'descent'::text, 'synthesis'::text, 'verification'::text]))),
    CONSTRAINT ck_phases_mass_pair CHECK (((frontier_open IS NULL) = (frontier_mass IS NULL))),
    CONSTRAINT ck_phases_round CHECK ((round_no >= 1)),
    CONSTRAINT ck_phases_snapshots_only_after_start CHECK (((frontier_open IS NULL) OR (state = ANY (ARRAY['complete'::text, 'failed'::text])))),
    CONSTRAINT ck_phases_state CHECK ((state = ANY (ARRAY['pending'::text, 'running'::text, 'complete'::text, 'failed'::text]))),
    CONSTRAINT ck_phases_times CHECK (((ended_at IS NULL) OR ((started_at IS NOT NULL) AND (ended_at >= started_at)))),
    CONSTRAINT ck_phases_wall CHECK (((wall_timeout_s IS NULL) OR (wall_timeout_s > 0)))
);


--
-- Name: quest_lifecycle_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quest_lifecycle_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    quest_id uuid NOT NULL,
    from_state text NOT NULL,
    to_state text NOT NULL,
    actor text NOT NULL,
    verification_phase_id uuid,
    verification_phase_kind text DEFAULT 'verification'::text NOT NULL,
    verification_phase_state text DEFAULT 'complete'::text NOT NULL,
    claims_at_archive integer,
    evidence_at_archive integer,
    frontier_open_at_archive integer,
    graph_fingerprint character(64),
    occurred_at timestamp with time zone NOT NULL,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_qle_actor CHECK ((actor = ANY (ARRAY['operator'::text, 'orchestrator'::text]))),
    CONSTRAINT ck_qle_claims_nonneg CHECK (((claims_at_archive IS NULL) OR (claims_at_archive >= 0))),
    CONSTRAINT ck_qle_evidence_nonneg CHECK (((evidence_at_archive IS NULL) OR (evidence_at_archive >= 0))),
    CONSTRAINT ck_qle_from_state CHECK ((from_state = ANY (ARRAY['active'::text, 'paused'::text, 'complete'::text, 'stopped'::text, 'archived'::text]))),
    CONSTRAINT ck_qle_frontier_open_nonneg CHECK (((frontier_open_at_archive IS NULL) OR (frontier_open_at_archive >= 0))),
    CONSTRAINT ck_qle_graph_fingerprint_format CHECK (((graph_fingerprint IS NULL) OR ((graph_fingerprint)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT ck_qle_to_state CHECK ((to_state = ANY (ARRAY['active'::text, 'paused'::text, 'complete'::text, 'stopped'::text, 'archived'::text]))),
    CONSTRAINT ck_qle_verification_kind CHECK ((verification_phase_kind = 'verification'::text)),
    CONSTRAINT ck_qle_verification_state CHECK ((verification_phase_state = 'complete'::text)),
    CONSTRAINT ck_quest_lifecycle_archive_counts_pair CHECK (((to_state = 'archived'::text) = ((claims_at_archive IS NOT NULL) AND (evidence_at_archive IS NOT NULL) AND (frontier_open_at_archive IS NOT NULL)))),
    CONSTRAINT ck_quest_lifecycle_archive_fingerprint_pair CHECK (((to_state = 'archived'::text) = (graph_fingerprint IS NOT NULL))),
    CONSTRAINT ck_quest_lifecycle_archive_pair CHECK (((to_state = 'archived'::text) = (verification_phase_id IS NOT NULL))),
    CONSTRAINT ck_quest_lifecycle_transition CHECK ((((from_state = 'active'::text) AND (to_state = 'paused'::text)) OR ((from_state = 'paused'::text) AND (to_state = 'active'::text)) OR ((from_state = 'active'::text) AND (to_state = 'complete'::text)) OR ((from_state = 'paused'::text) AND (to_state = 'complete'::text)) OR ((from_state = 'active'::text) AND (to_state = 'stopped'::text)) OR ((from_state = 'paused'::text) AND (to_state = 'stopped'::text)) OR ((from_state = 'stopped'::text) AND (to_state = 'active'::text)) OR ((from_state = 'complete'::text) AND (to_state = 'archived'::text)) OR ((from_state = 'stopped'::text) AND (to_state = 'archived'::text))))
);


--
-- Name: quest_sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quest_sources (
    quest_id uuid NOT NULL,
    source_id uuid NOT NULL,
    user_id uuid NOT NULL,
    added_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: quests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    topic text NOT NULL,
    state text DEFAULT 'active'::text NOT NULL,
    provenance_kind text DEFAULT 'fresh'::text NOT NULL,
    source_quest_id uuid,
    web_call_budget integer NOT NULL,
    token_budget integer NOT NULL,
    spend_budget_usd numeric(12,4) NOT NULL,
    model_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    process_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_quests_provenance CHECK ((provenance_kind = ANY (ARRAY['fresh'::text, 'from_corpus'::text, 'graph_graft'::text]))),
    CONSTRAINT ck_quests_provenance_pair CHECK (((provenance_kind = 'fresh'::text) = (source_quest_id IS NULL))),
    CONSTRAINT ck_quests_spend_budget CHECK ((spend_budget_usd >= (0)::numeric)),
    CONSTRAINT ck_quests_state CHECK ((state = ANY (ARRAY['active'::text, 'paused'::text, 'complete'::text, 'stopped'::text, 'archived'::text]))),
    CONSTRAINT ck_quests_token_budget CHECK ((token_budget >= 0)),
    CONSTRAINT ck_quests_topic_nonempty CHECK ((char_length(btrim(topic)) > 0)),
    CONSTRAINT ck_quests_web_budget CHECK ((web_call_budget >= 0))
);


--
-- Name: report_citations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.report_citations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    quest_id uuid NOT NULL,
    report_version_id uuid NOT NULL,
    ordinal integer NOT NULL,
    source_id uuid,
    source_anchorable boolean DEFAULT true NOT NULL,
    imported_source_id uuid,
    imported_source_anchorable boolean DEFAULT true NOT NULL,
    imported boolean DEFAULT false NOT NULL,
    import_source_quest_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_report_citations_citable CHECK (source_anchorable),
    CONSTRAINT ck_report_citations_import_citable CHECK (imported_source_anchorable),
    CONSTRAINT ck_report_citations_import_pair CHECK (((imported = (imported_source_id IS NOT NULL)) AND (imported = (import_source_quest_id IS NOT NULL)))),
    CONSTRAINT ck_report_citations_ordinal CHECK ((ordinal >= 1)),
    CONSTRAINT ck_report_citations_resource_exactly_one CHECK (((source_id IS NULL) <> (imported_source_id IS NULL)))
);


--
-- Name: report_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.report_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    quest_id uuid NOT NULL,
    version_seq integer NOT NULL,
    synthesis_phase_id uuid NOT NULL,
    synthesis_phase_kind text DEFAULT 'synthesis'::text NOT NULL,
    created_session_id uuid NOT NULL,
    model text NOT NULL,
    body_blob_key text NOT NULL,
    body_sha256 character(64) NOT NULL,
    quest_fingerprint character(64) NOT NULL,
    standing boolean DEFAULT false NOT NULL,
    bound_at timestamp with time zone,
    binding_pass text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_report_versions_binding_pair CHECK (((bound_at IS NULL) = (binding_pass IS NULL))),
    CONSTRAINT ck_report_versions_binding_pass_nonempty CHECK (((binding_pass IS NULL) OR (char_length(btrim(binding_pass)) > 0))),
    CONSTRAINT ck_report_versions_body_key CHECK ((body_blob_key ~ '^reports/[0-9a-f-]{36}/v[0-9]+\.md$'::text)),
    CONSTRAINT ck_report_versions_body_sha CHECK (((body_sha256)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT ck_report_versions_model_nonempty CHECK ((char_length(btrim(model)) > 0)),
    CONSTRAINT ck_report_versions_phase_kind CHECK ((synthesis_phase_kind = 'synthesis'::text)),
    CONSTRAINT ck_report_versions_quest_fingerprint CHECK (((quest_fingerprint)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT ck_report_versions_seq CHECK ((version_seq >= 1))
);


--
-- Name: resource_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_grants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    owner_user_id uuid NOT NULL,
    source_id uuid NOT NULL,
    grantee_user_id uuid,
    grantee_workspace_id uuid,
    is_public boolean DEFAULT false NOT NULL,
    note text,
    granted_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_resource_grants_grantee_exactly_one CHECK ((((((grantee_user_id IS NOT NULL))::integer + ((grantee_workspace_id IS NOT NULL))::integer) + (is_public)::integer) = 1))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    filename text NOT NULL
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    quest_id uuid NOT NULL,
    phase_id uuid NOT NULL,
    mode text NOT NULL,
    driver text NOT NULL,
    model text NOT NULL,
    transcript_blob_key text,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    ended_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_sessions_driver CHECK ((driver = ANY (ARRAY['orchestrator'::text, 'operator'::text]))),
    CONSTRAINT ck_sessions_mode CHECK ((mode = ANY (ARRAY['autonomous'::text, 'interactive'::text]))),
    CONSTRAINT ck_sessions_model_nonempty CHECK ((char_length(btrim(model)) > 0)),
    CONSTRAINT ck_sessions_times CHECK (((ended_at IS NULL) OR (ended_at >= started_at))),
    CONSTRAINT ck_sessions_transcript_key CHECK ((transcript_blob_key ~ '^sessions/[0-9a-f-]{36}/transcript\.jsonl$'::text))
);


--
-- Name: sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    url text NOT NULL,
    canonical_url text NOT NULL,
    urn text NOT NULL,
    title text NOT NULL,
    role text NOT NULL,
    published_at timestamp with time zone,
    fetched_at timestamp with time zone NOT NULL,
    snapshot_sha256 character(64) NOT NULL,
    raw_sha256 character(64) NOT NULL,
    snapshot_blob_key text GENERATED ALWAYS AS (((('blobs/sha256/'::text || substr((snapshot_sha256)::text, 1, 2)) || '/'::text) || (snapshot_sha256)::text)) STORED,
    raw_blob_key text GENERATED ALWAYS AS (((('blobs/sha256/'::text || substr((raw_sha256)::text, 1, 2)) || '/'::text) || (raw_sha256)::text)) STORED,
    snapshot_char_count integer NOT NULL,
    anchorable boolean GENERATED ALWAYS AS ((role = 'citable'::text)) STORED,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_sources_canonical_url CHECK ((canonical_url ~ '^https?://'::text)),
    CONSTRAINT ck_sources_raw_sha CHECK (((raw_sha256)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT ck_sources_role CHECK ((role = ANY (ARRAY['citable'::text, 'agenda'::text]))),
    CONSTRAINT ck_sources_snapshot_chars CHECK ((snapshot_char_count > 0)),
    CONSTRAINT ck_sources_snapshot_sha CHECK (((snapshot_sha256)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT ck_sources_title_nonempty CHECK ((char_length(btrim(title)) > 0)),
    CONSTRAINT ck_sources_url CHECK ((url ~ '^https?://'::text)),
    CONSTRAINT ck_sources_urn_format CHECK ((urn ~ '^kb:src:[1-9A-HJ-NP-Za-km-z]{10}$'::text))
);


--
-- Name: stop_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stop_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    rule_id text NOT NULL,
    scope text NOT NULL,
    metric text NOT NULL,
    "default" numeric NOT NULL,
    operator text NOT NULL,
    action text NOT NULL,
    provenance text NOT NULL,
    config_key text NOT NULL,
    CONSTRAINT ck_stop_rules_action CHECK ((action = ANY (ARRAY['route-to-synthesis'::text, 'pause-and-present'::text, 'stop-loud'::text, 'adjust'::text]))),
    CONSTRAINT ck_stop_rules_config_key_nonempty CHECK ((char_length(btrim(config_key)) > 0)),
    CONSTRAINT ck_stop_rules_metric_nonempty CHECK ((char_length(btrim(metric)) > 0)),
    CONSTRAINT ck_stop_rules_operator CHECK ((operator = ANY (ARRAY['>='::text, '>'::text, '<='::text, '<'::text]))),
    CONSTRAINT ck_stop_rules_rule_id CHECK ((rule_id ~ '^SR-[0-9]{2}$'::text)),
    CONSTRAINT ck_stop_rules_scope CHECK ((scope = ANY (ARRAY['quest'::text, 'phase'::text])))
);


--
-- Name: tool_calls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_calls (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    quest_id uuid NOT NULL,
    session_id uuid NOT NULL,
    seq integer NOT NULL,
    tool text NOT NULL,
    op text,
    args jsonb NOT NULL,
    result jsonb NOT NULL,
    ok boolean NOT NULL,
    error_class text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_tool_calls_error_shape CHECK (((ok AND (error_class IS NULL)) OR ((NOT ok) AND (error_class IS NOT NULL)))),
    CONSTRAINT ck_tool_calls_seq CHECK ((seq >= 1)),
    CONSTRAINT ck_tool_calls_tool_nonempty CHECK ((char_length(btrim(tool)) > 0))
);


--
-- Name: usage_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    quest_id uuid NOT NULL,
    phase_id uuid NOT NULL,
    session_id uuid NOT NULL,
    kind text NOT NULL,
    model text NOT NULL,
    input_tokens integer NOT NULL,
    output_tokens integer NOT NULL,
    cache_read_tokens integer DEFAULT 0 NOT NULL,
    cache_write_tokens integer DEFAULT 0 NOT NULL,
    reasoning_tokens integer DEFAULT 0 NOT NULL,
    seed integer,
    cost_usd numeric(12,6),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_usage_cache_read CHECK ((cache_read_tokens >= 0)),
    CONSTRAINT ck_usage_cache_write CHECK ((cache_write_tokens >= 0)),
    CONSTRAINT ck_usage_cost CHECK (((cost_usd IS NULL) OR (cost_usd >= (0)::numeric))),
    CONSTRAINT ck_usage_input CHECK ((input_tokens >= 0)),
    CONSTRAINT ck_usage_kind CHECK ((kind = ANY (ARRAY['llm'::text, 'embedding'::text]))),
    CONSTRAINT ck_usage_model_nonempty CHECK ((char_length(btrim(model)) > 0)),
    CONSTRAINT ck_usage_output CHECK ((output_tokens >= 0)),
    CONSTRAINT ck_usage_reasoning CHECK ((reasoning_tokens >= 0)),
    CONSTRAINT ck_usage_seed CHECK (((seed IS NULL) OR (seed >= 0)))
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    handle text NOT NULL,
    display_name text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    github_uid text DEFAULT ''::text NOT NULL,
    username text DEFAULT ''::text NOT NULL,
    name text,
    email text,
    avatar_url text,
    updated_at timestamp with time zone,
    CONSTRAINT ck_users_handle CHECK ((handle ~ '^[a-z0-9][a-z0-9_-]{1,31}$'::text))
);


--
-- Name: v_canonical_claims; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_canonical_claims AS
 SELECT user_id,
    canonical_text,
    terminal_type,
    array_agg(id ORDER BY quest_id, id) AS member_claim_ids,
    count(DISTINCT quest_id) AS quest_count,
    min(created_at) AS first_seen,
    max(created_at) AS latest_seen,
    (count(*) FILTER (WHERE (terminal_type IS NOT NULL)) OVER (PARTITION BY user_id, canonical_text) > 1) AS type_divergent
   FROM public.claims c
  GROUP BY user_id, canonical_text, terminal_type;


--
-- Name: v_claim_closure; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_claim_closure AS
 SELECT quest_id,
    id AS claim_id,
    quest_seq,
    canonical_text,
    (terminal_type IS NOT NULL) AS has_terminal,
    terminal_type,
    ( SELECT count(*) AS count
           FROM public.claim_derivations d
          WHERE (d.claim_id = c.id)) AS derives_from_count,
    ( SELECT count(*) AS count
           FROM public.evidence_edges ee
          WHERE (ee.claim_id = c.id)) AS evidence_count,
    ( SELECT count(*) AS count
           FROM public.frontier_entries f
          WHERE ((f.claim_id = c.id) AND (f.state = 'open'::text))) AS open_frontier_count,
    ((terminal_type IS NULL) AND (NOT (EXISTS ( SELECT 1
           FROM public.claim_derivations d
          WHERE (d.claim_id = c.id)))) AND (NOT (EXISTS ( SELECT 1
           FROM public.frontier_entries f
          WHERE ((f.claim_id = c.id) AND (f.state = 'open'::text)))))) AS bare
   FROM public.claims c;


--
-- Name: v_unmined_sources; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_unmined_sources AS
 SELECT qs.quest_id,
    qs.source_id,
    s.urn,
    s.title
   FROM (public.quest_sources qs
     JOIN public.sources s ON (((s.id = qs.source_id) AND (s.user_id = qs.user_id))))
  WHERE ((s.role = 'citable'::text) AND (NOT (EXISTS ( SELECT 1
           FROM public.evidence e
          WHERE ((e.source_id = qs.source_id) AND (e.quest_id = qs.quest_id))))));


--
-- Name: v_decompose_remaining; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_decompose_remaining AS
 SELECT quest_id,
    count(*) AS unmined_citable
   FROM public.v_unmined_sources
  GROUP BY quest_id;


--
-- Name: v_frontier_open; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_frontier_open AS
 SELECT f.quest_id,
    f.id AS entry_id,
    f.claim_id,
    c.quest_seq AS claim_seq,
    f.need,
    f.uncertainty,
    f.relevance,
    (f.uncertainty * f.relevance) AS mass,
    f.spawned_by_phase_id,
    f.opened_at
   FROM (public.frontier_entries f
     JOIN public.claims c ON (((c.id = f.claim_id) AND (c.quest_id = f.quest_id))))
  WHERE (f.state = 'open'::text)
  ORDER BY f.quest_id, (f.uncertainty * f.relevance) DESC, c.quest_seq, f.id;


--
-- Name: v_frontier_mass; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_frontier_mass AS
 SELECT quest_id,
    count(*) AS open_entries,
    COALESCE(sum(mass), (0)::bigint) AS mass
   FROM public.v_frontier_open
  GROUP BY quest_id;


--
-- Name: v_quest_graph_fingerprint; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_quest_graph_fingerprint AS
 SELECT id AS quest_id,
    encode(sha256(convert_to((((((((((((((((((('kquest-graph-fingerprint/1'::text || chr(10)) || 'corpus:'::text) || COALESCE(( SELECT string_agg(((
                CASE
                    WHEN (qs.source_id IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to((qs.source_id)::text, 'UTF8'::name))) || ':'::text) || (qs.source_id)::text)
                END || ';'::text) ||
                CASE
                    WHEN (qs.added_at IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to((EXTRACT(epoch FROM qs.added_at))::text, 'UTF8'::name))) || ':'::text) || (EXTRACT(epoch FROM qs.added_at))::text)
                END), chr(10) ORDER BY qs.source_id) AS string_agg
           FROM public.quest_sources qs
          WHERE (qs.quest_id = q.id)), ''::text)) || chr(10)) || 'claims:'::text) || COALESCE(( SELECT string_agg(((((((((((((('S'::text || octet_length(convert_to((c.quest_seq)::text, 'UTF8'::name))) || ':'::text) || (c.quest_seq)::text) || ';'::text) ||
                CASE
                    WHEN (c.id IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to((c.id)::text, 'UTF8'::name))) || ':'::text) || (c.id)::text)
                END) || ';'::text) ||
                CASE
                    WHEN (c.canonical_text IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to(c.canonical_text, 'UTF8'::name))) || ':'::text) || c.canonical_text)
                END) || ';'::text) ||
                CASE
                    WHEN (c.terminal_type IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to(c.terminal_type, 'UTF8'::name))) || ':'::text) || c.terminal_type)
                END) || ';'::text) ||
                CASE
                    WHEN (c.terminal_basis IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to(c.terminal_basis, 'UTF8'::name))) || ':'::text) || c.terminal_basis)
                END) || ';'::text) ||
                CASE
                    WHEN (c.origin_quest_id IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to((c.origin_quest_id)::text, 'UTF8'::name))) || ':'::text) || (c.origin_quest_id)::text)
                END), chr(10) ORDER BY c.quest_seq, c.id) AS string_agg
           FROM public.claims c
          WHERE (c.quest_id = q.id)), ''::text)) || chr(10)) || 'evidence:'::text) || COALESCE(( SELECT string_agg(((((((((((((((((
                CASE
                    WHEN (e.id IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to((e.id)::text, 'UTF8'::name))) || ':'::text) || (e.id)::text)
                END || ';'::text) ||
                CASE
                    WHEN (e.source_id IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to((e.source_id)::text, 'UTF8'::name))) || ':'::text) || (e.source_id)::text)
                END) || ';'::text) || 'S'::text) || octet_length(convert_to((e.span_start)::text, 'UTF8'::name))) || ':'::text) || (e.span_start)::text) || ';'::text) || 'S'::text) || octet_length(convert_to((e.span_end)::text, 'UTF8'::name))) || ':'::text) || (e.span_end)::text) || ';'::text) ||
                CASE
                    WHEN (e.span_text IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to(e.span_text, 'UTF8'::name))) || ':'::text) || e.span_text)
                END) || ';'::text) ||
                CASE
                    WHEN (e.reading IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to(e.reading, 'UTF8'::name))) || ':'::text) || e.reading)
                END), chr(10) ORDER BY e.source_id, e.span_start, e.span_end, e.id) AS string_agg
           FROM public.evidence e
          WHERE (e.quest_id = q.id)), ''::text)) || chr(10)) || 'edges:'::text) || COALESCE(( SELECT string_agg((((((((((
                CASE
                    WHEN (ee.evidence_id IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to((ee.evidence_id)::text, 'UTF8'::name))) || ':'::text) || (ee.evidence_id)::text)
                END || ';'::text) ||
                CASE
                    WHEN (ee.relation IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to(ee.relation, 'UTF8'::name))) || ':'::text) || ee.relation)
                END) || ';'::text) ||
                CASE
                    WHEN (ee.claim_id IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to((ee.claim_id)::text, 'UTF8'::name))) || ':'::text) || (ee.claim_id)::text)
                END) || ';'::text) || 'S'::text) || octet_length(convert_to((ee."position")::text, 'UTF8'::name))) || ':'::text) || (ee."position")::text), chr(10) ORDER BY ee.evidence_id, ee.relation, ee."position") AS string_agg
           FROM public.evidence_edges ee
          WHERE (ee.quest_id = q.id)), ''::text)) || chr(10)) || 'derivations:'::text) || COALESCE(( SELECT string_agg((((((((
                CASE
                    WHEN (cd.claim_id IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to((cd.claim_id)::text, 'UTF8'::name))) || ':'::text) || (cd.claim_id)::text)
                END || ';'::text) ||
                CASE
                    WHEN (cd.parent_claim_id IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to((cd.parent_claim_id)::text, 'UTF8'::name))) || ':'::text) || (cd.parent_claim_id)::text)
                END) || ';'::text) || 'S'::text) || octet_length(convert_to((cd."position")::text, 'UTF8'::name))) || ':'::text) || (cd."position")::text), chr(10) ORDER BY cd.claim_id, cd."position") AS string_agg
           FROM public.claim_derivations cd
          WHERE (cd.quest_id = q.id)), ''::text)) || chr(10)) || 'frontier:'::text) || COALESCE(( SELECT string_agg(((((((((((((((((
                CASE
                    WHEN (f.claim_id IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to((f.claim_id)::text, 'UTF8'::name))) || ':'::text) || (f.claim_id)::text)
                END || ';'::text) ||
                CASE
                    WHEN (f.need IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to(f.need, 'UTF8'::name))) || ':'::text) || f.need)
                END) || ';'::text) || 'S'::text) || octet_length(convert_to((f.uncertainty)::text, 'UTF8'::name))) || ':'::text) || (f.uncertainty)::text) || ';'::text) || 'S'::text) || octet_length(convert_to((f.relevance)::text, 'UTF8'::name))) || ':'::text) || (f.relevance)::text) || ';'::text) ||
                CASE
                    WHEN (f.state IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to(f.state, 'UTF8'::name))) || ':'::text) || f.state)
                END) || ';'::text) ||
                CASE
                    WHEN (f.closure_type IS NULL) THEN 'N'::text
                    ELSE ((('S'::text || octet_length(convert_to(f.closure_type, 'UTF8'::name))) || ':'::text) || f.closure_type)
                END), chr(10) ORDER BY f.need) AS string_agg
           FROM public.frontier_entries f
          WHERE (f.quest_id = q.id)), ''::text)), 'UTF8'::name)), 'hex'::text) AS graph_fingerprint
   FROM public.quests q;


--
-- Name: v_quest_lineage; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_quest_lineage AS
 WITH RECURSIVE lin(quest_id, ancestor_quest_id, via_provenance_kind, depth) AS (
         SELECT q_1.id,
            q_1.source_quest_id,
            q_1.provenance_kind,
            1 AS "?column?"
           FROM public.quests q_1
          WHERE (q_1.source_quest_id IS NOT NULL)
        UNION ALL
         SELECT l.quest_id,
            q2.source_quest_id,
            q2.provenance_kind,
            (l.depth + 1)
           FROM (lin l
             JOIN public.quests q2 ON ((q2.id = l.ancestor_quest_id)))
          WHERE ((q2.source_quest_id IS NOT NULL) AND (l.depth < 20))
        )
 SELECT lin.quest_id,
    q.topic,
    lin.ancestor_quest_id,
    qa.topic AS ancestor_topic,
    lin.via_provenance_kind,
    lin.depth
   FROM ((lin
     JOIN public.quests q ON ((q.id = lin.quest_id)))
     JOIN public.quests qa ON ((qa.id = lin.ancestor_quest_id)));


--
-- Name: v_resource_visibility; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_resource_visibility AS
 SELECT 'source'::text AS resource_kind,
    source_id AS resource_id,
    owner_user_id,
        CASE
            WHEN bool_or(is_public) THEN 'public'::text
            WHEN (count(grantee_workspace_id) > 0) THEN 'workspace'::text
            ELSE 'shared'::text
        END AS effective_scope
   FROM public.resource_grants rg
  GROUP BY source_id, owner_user_id;


--
-- Name: workspace_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspace_members (
    workspace_id uuid NOT NULL,
    user_id uuid NOT NULL,
    joined_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: workspaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspaces (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    created_by_user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_workspaces_name CHECK ((name ~ '^[a-z0-9][a-z0-9-]{0,63}$'::text))
);


--
-- Name: chunk_strategies chunk_strategies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chunk_strategies
    ADD CONSTRAINT chunk_strategies_pkey PRIMARY KEY (id);


--
-- Name: chunks chunks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chunks
    ADD CONSTRAINT chunks_pkey PRIMARY KEY (id);


--
-- Name: claim_derivations claim_derivations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_derivations
    ADD CONSTRAINT claim_derivations_pkey PRIMARY KEY (id);


--
-- Name: claims claims_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claims
    ADD CONSTRAINT claims_pkey PRIMARY KEY (id);


--
-- Name: conflicts conflicts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conflicts
    ADD CONSTRAINT conflicts_pkey PRIMARY KEY (id);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (id);


--
-- Name: emb_bge_m3_1024 emb_bge_m3_1024_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_bge_m3_1024
    ADD CONSTRAINT emb_bge_m3_1024_pkey PRIMARY KEY (id);


--
-- Name: emb_minilm_ab_384 emb_minilm_ab_384_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_minilm_ab_384
    ADD CONSTRAINT emb_minilm_ab_384_pkey PRIMARY KEY (id);


--
-- Name: embed_jobs embed_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embed_jobs
    ADD CONSTRAINT embed_jobs_pkey PRIMARY KEY (id);


--
-- Name: embedding_models embedding_models_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embedding_models
    ADD CONSTRAINT embedding_models_pkey PRIMARY KEY (id);


--
-- Name: evidence_edges evidence_edges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence_edges
    ADD CONSTRAINT evidence_edges_pkey PRIMARY KEY (id);


--
-- Name: evidence evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT evidence_pkey PRIMARY KEY (id);


--
-- Name: frontier_entries frontier_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.frontier_entries
    ADD CONSTRAINT frontier_entries_pkey PRIMARY KEY (id);


--
-- Name: ladder_passes ladder_passes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ladder_passes
    ADD CONSTRAINT ladder_passes_pkey PRIMARY KEY (id);


--
-- Name: phase_transitions phase_transitions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phase_transitions
    ADD CONSTRAINT phase_transitions_pkey PRIMARY KEY (id);


--
-- Name: phases phases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phases
    ADD CONSTRAINT phases_pkey PRIMARY KEY (id);


--
-- Name: conflict_sources pk_conflict_sources; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conflict_sources
    ADD CONSTRAINT pk_conflict_sources PRIMARY KEY (conflict_id, source_id);


--
-- Name: quest_sources pk_quest_sources; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_sources
    ADD CONSTRAINT pk_quest_sources PRIMARY KEY (quest_id, source_id);


--
-- Name: workspace_members pk_workspace_members; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_members
    ADD CONSTRAINT pk_workspace_members PRIMARY KEY (workspace_id, user_id);


--
-- Name: quest_lifecycle_events quest_lifecycle_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_lifecycle_events
    ADD CONSTRAINT quest_lifecycle_events_pkey PRIMARY KEY (id);


--
-- Name: quests quests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quests
    ADD CONSTRAINT quests_pkey PRIMARY KEY (id);


--
-- Name: report_citations report_citations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_citations
    ADD CONSTRAINT report_citations_pkey PRIMARY KEY (id);


--
-- Name: report_versions report_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_versions
    ADD CONSTRAINT report_versions_pkey PRIMARY KEY (id);


--
-- Name: resource_grants resource_grants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_grants
    ADD CONSTRAINT resource_grants_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (filename);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: sources sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_pkey PRIMARY KEY (id);


--
-- Name: stop_rules stop_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stop_rules
    ADD CONSTRAINT stop_rules_pkey PRIMARY KEY (id);


--
-- Name: tool_calls tool_calls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_calls
    ADD CONSTRAINT tool_calls_pkey PRIMARY KEY (id);


--
-- Name: chunk_strategies uq_chunk_strategies_name_version; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chunk_strategies
    ADD CONSTRAINT uq_chunk_strategies_name_version UNIQUE (name, version);


--
-- Name: chunks uq_chunks_id_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chunks
    ADD CONSTRAINT uq_chunks_id_user UNIQUE (id, user_id);


--
-- Name: chunks uq_chunks_source_strategy_ordinal; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chunks
    ADD CONSTRAINT uq_chunks_source_strategy_ordinal UNIQUE (source_id, strategy_id, ordinal);


--
-- Name: claim_derivations uq_claim_derivations_positions; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_derivations
    ADD CONSTRAINT uq_claim_derivations_positions UNIQUE (claim_id, "position");


--
-- Name: claims uq_claims_id_quest; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claims
    ADD CONSTRAINT uq_claims_id_quest UNIQUE (id, quest_id);


--
-- Name: claims uq_claims_id_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claims
    ADD CONSTRAINT uq_claims_id_user UNIQUE (id, user_id);


--
-- Name: claims uq_claims_quest_canonical; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claims
    ADD CONSTRAINT uq_claims_quest_canonical UNIQUE (quest_id, canonical_text);


--
-- Name: claims uq_claims_quest_seq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claims
    ADD CONSTRAINT uq_claims_quest_seq UNIQUE (quest_id, quest_seq);


--
-- Name: claims uq_claims_quest_urn; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claims
    ADD CONSTRAINT uq_claims_quest_urn UNIQUE (quest_id, urn);


--
-- Name: emb_bge_m3_1024 uq_emb_bge_m3_1024_id_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_bge_m3_1024
    ADD CONSTRAINT uq_emb_bge_m3_1024_id_user UNIQUE (id, user_id);


--
-- Name: emb_bge_m3_1024 uq_emb_bge_m3_1024_target; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_bge_m3_1024
    ADD CONSTRAINT uq_emb_bge_m3_1024_target UNIQUE NULLS NOT DISTINCT (target_kind, chunk_id, claim_id, need_id);


--
-- Name: emb_minilm_ab_384 uq_emb_minilm_ab_384_id_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_minilm_ab_384
    ADD CONSTRAINT uq_emb_minilm_ab_384_id_user UNIQUE (id, user_id);


--
-- Name: emb_minilm_ab_384 uq_emb_minilm_ab_384_target; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_minilm_ab_384
    ADD CONSTRAINT uq_emb_minilm_ab_384_target UNIQUE NULLS NOT DISTINCT (target_kind, chunk_id, claim_id, need_id);


--
-- Name: embed_jobs uq_embed_jobs_id_quest; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embed_jobs
    ADD CONSTRAINT uq_embed_jobs_id_quest UNIQUE (id, quest_id);


--
-- Name: embed_jobs uq_embed_jobs_id_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embed_jobs
    ADD CONSTRAINT uq_embed_jobs_id_user UNIQUE (id, user_id);


--
-- Name: embedding_models uq_embedding_models_id_status; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embedding_models
    ADD CONSTRAINT uq_embedding_models_id_status UNIQUE (id, status);


--
-- Name: embedding_models uq_embedding_models_provider_wire; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embedding_models
    ADD CONSTRAINT uq_embedding_models_provider_wire UNIQUE (provider, wire_name);


--
-- Name: embedding_models uq_embedding_models_slug; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embedding_models
    ADD CONSTRAINT uq_embedding_models_slug UNIQUE (slug);


--
-- Name: embedding_models uq_embedding_models_table_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embedding_models
    ADD CONSTRAINT uq_embedding_models_table_name UNIQUE (table_name);


--
-- Name: evidence_edges uq_evidence_edges_positions; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence_edges
    ADD CONSTRAINT uq_evidence_edges_positions UNIQUE (evidence_id, relation, "position");


--
-- Name: evidence uq_evidence_id_quest; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT uq_evidence_id_quest UNIQUE (id, quest_id);


--
-- Name: evidence uq_evidence_quest_span; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT uq_evidence_quest_span UNIQUE (quest_id, source_id, span_start, span_end);


--
-- Name: frontier_entries uq_frontier_id_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.frontier_entries
    ADD CONSTRAINT uq_frontier_id_user UNIQUE (id, user_id);


--
-- Name: frontier_entries uq_frontier_need; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.frontier_entries
    ADD CONSTRAINT uq_frontier_need UNIQUE (quest_id, need);


--
-- Name: phase_transitions uq_phase_transitions_ordinal; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phase_transitions
    ADD CONSTRAINT uq_phase_transitions_ordinal UNIQUE (ordinal);


--
-- Name: phases uq_phases_id_quest; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phases
    ADD CONSTRAINT uq_phases_id_quest UNIQUE (id, quest_id);


--
-- Name: phases uq_phases_id_quest_kind; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phases
    ADD CONSTRAINT uq_phases_id_quest_kind UNIQUE (id, quest_id, kind);


--
-- Name: phases uq_phases_id_quest_kind_state; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phases
    ADD CONSTRAINT uq_phases_id_quest_kind_state UNIQUE (id, quest_id, kind, state);


--
-- Name: phases uq_phases_quest_kind_round_attempt; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phases
    ADD CONSTRAINT uq_phases_quest_kind_round_attempt UNIQUE (quest_id, kind, round_no, attempt_no);


--
-- Name: quests uq_quests_id_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quests
    ADD CONSTRAINT uq_quests_id_user UNIQUE (id, user_id);


--
-- Name: report_citations uq_report_citations_id_version; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_citations
    ADD CONSTRAINT uq_report_citations_id_version UNIQUE (id, report_version_id);


--
-- Name: report_citations uq_report_citations_ordinal; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_citations
    ADD CONSTRAINT uq_report_citations_ordinal UNIQUE (report_version_id, ordinal);


--
-- Name: report_versions uq_report_versions_id_quest; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_versions
    ADD CONSTRAINT uq_report_versions_id_quest UNIQUE (id, quest_id);


--
-- Name: report_versions uq_report_versions_quest_seq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_versions
    ADD CONSTRAINT uq_report_versions_quest_seq UNIQUE (quest_id, version_seq);


--
-- Name: sessions uq_sessions_id_phase; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT uq_sessions_id_phase UNIQUE (id, phase_id);


--
-- Name: sessions uq_sessions_id_quest; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT uq_sessions_id_quest UNIQUE (id, quest_id);


--
-- Name: sources uq_sources_id_anchorable; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT uq_sources_id_anchorable UNIQUE (id, anchorable);


--
-- Name: sources uq_sources_id_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT uq_sources_id_user UNIQUE (id, user_id);


--
-- Name: sources uq_sources_id_user_anchorable; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT uq_sources_id_user_anchorable UNIQUE (id, user_id, anchorable);


--
-- Name: sources uq_sources_id_user_anchorable_chars; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT uq_sources_id_user_anchorable_chars UNIQUE (id, user_id, anchorable, snapshot_char_count);


--
-- Name: sources uq_sources_user_urn; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT uq_sources_user_urn UNIQUE (user_id, urn);


--
-- Name: stop_rules uq_stop_rules_config_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stop_rules
    ADD CONSTRAINT uq_stop_rules_config_key UNIQUE (config_key);


--
-- Name: stop_rules uq_stop_rules_rule_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stop_rules
    ADD CONSTRAINT uq_stop_rules_rule_id UNIQUE (rule_id);


--
-- Name: tool_calls uq_tool_calls_session_seq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_calls
    ADD CONSTRAINT uq_tool_calls_session_seq UNIQUE (session_id, seq);


--
-- Name: usage_events uq_usage_events_id_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events
    ADD CONSTRAINT uq_usage_events_id_user UNIQUE (id, user_id);


--
-- Name: users uq_users_handle; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT uq_users_handle UNIQUE (handle);


--
-- Name: workspaces uq_workspaces_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT uq_workspaces_name UNIQUE (name);


--
-- Name: usage_events usage_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events
    ADD CONSTRAINT usage_events_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: workspaces workspaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_pkey PRIMARY KEY (id);


--
-- Name: idx_chunks_search_tsv; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chunks_search_tsv ON public.chunks USING gin (search_tsv);


--
-- Name: idx_chunks_strategy; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chunks_strategy ON public.chunks USING btree (strategy_id);


--
-- Name: idx_claim_derivations_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_claim_derivations_parent ON public.claim_derivations USING btree (parent_claim_id);


--
-- Name: idx_claims_origin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_claims_origin ON public.claims USING btree (origin_quest_id);


--
-- Name: idx_emb_bge_m3_1024_hnsw; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_emb_bge_m3_1024_hnsw ON public.emb_bge_m3_1024 USING hnsw (embedding public.vector_cosine_ops);


--
-- Name: idx_emb_bge_m3_1024_job; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_emb_bge_m3_1024_job ON public.emb_bge_m3_1024 USING btree (job_id);


--
-- Name: idx_emb_bge_m3_1024_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_emb_bge_m3_1024_user ON public.emb_bge_m3_1024 USING btree (user_id);


--
-- Name: idx_emb_minilm_ab_384_hnsw; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_emb_minilm_ab_384_hnsw ON public.emb_minilm_ab_384 USING hnsw (embedding public.vector_cosine_ops);


--
-- Name: idx_emb_minilm_ab_384_job; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_emb_minilm_ab_384_job ON public.emb_minilm_ab_384 USING btree (job_id);


--
-- Name: idx_emb_minilm_ab_384_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_emb_minilm_ab_384_user ON public.emb_minilm_ab_384 USING btree (user_id);


--
-- Name: idx_embed_jobs_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_embed_jobs_state ON public.embed_jobs USING btree (state) WHERE (state = ANY (ARRAY['pending'::text, 'running'::text]));


--
-- Name: idx_embed_jobs_user_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_embed_jobs_user_created ON public.embed_jobs USING btree (user_id, created_at DESC);


--
-- Name: idx_evidence_edges_claim; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_evidence_edges_claim ON public.evidence_edges USING btree (claim_id, relation);


--
-- Name: idx_evidence_quest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_evidence_quest ON public.evidence USING btree (quest_id);


--
-- Name: idx_evidence_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_evidence_source ON public.evidence USING btree (source_id);


--
-- Name: idx_frontier_claim; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_frontier_claim ON public.frontier_entries USING btree (claim_id);


--
-- Name: idx_frontier_open_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_frontier_open_order ON public.frontier_entries USING btree (quest_id, ((uncertainty * relevance)) DESC, claim_id) WHERE (state = 'open'::text);


--
-- Name: idx_qle_quest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_qle_quest ON public.quest_lifecycle_events USING btree (quest_id, occurred_at);


--
-- Name: idx_quest_sources_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quest_sources_source ON public.quest_sources USING btree (source_id);


--
-- Name: idx_quests_user_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quests_user_created ON public.quests USING btree (user_id, created_at DESC);


--
-- Name: idx_report_citations_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_report_citations_source ON public.report_citations USING btree (source_id);


--
-- Name: idx_report_versions_quest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_report_versions_quest ON public.report_versions USING btree (quest_id, version_seq);


--
-- Name: idx_resource_grants_grantee_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_resource_grants_grantee_user ON public.resource_grants USING btree (grantee_user_id);


--
-- Name: idx_resource_grants_grantee_workspace; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_resource_grants_grantee_workspace ON public.resource_grants USING btree (grantee_workspace_id);


--
-- Name: idx_sessions_quest_started; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sessions_quest_started ON public.sessions USING btree (quest_id, started_at DESC);


--
-- Name: idx_sources_user_fetched; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sources_user_fetched ON public.sources USING btree (user_id, fetched_at DESC);


--
-- Name: idx_tool_calls_quest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tool_calls_quest ON public.tool_calls USING btree (quest_id, created_at DESC);


--
-- Name: idx_tool_calls_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tool_calls_session ON public.tool_calls USING btree (session_id);


--
-- Name: idx_usage_quest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_usage_quest ON public.usage_events USING btree (quest_id, created_at DESC);


--
-- Name: idx_usage_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_usage_session ON public.usage_events USING btree (session_id);


--
-- Name: idx_usage_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_usage_user ON public.usage_events USING btree (user_id, created_at DESC);


--
-- Name: idx_workspace_members_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_workspace_members_user ON public.workspace_members USING btree (user_id);


--
-- Name: index_users_on_github_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_github_uid ON public.users USING btree (github_uid);


--
-- Name: uq_embed_jobs_idem_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_embed_jobs_idem_active ON public.embed_jobs USING btree (idem_key) WHERE (state <> 'failed'::text);


--
-- Name: uq_frontier_open_per_claim; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_frontier_open_per_claim ON public.frontier_entries USING btree (quest_id, claim_id) WHERE (state = 'open'::text);


--
-- Name: uq_ladder_passes_rung; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_ladder_passes_rung ON public.ladder_passes USING btree (model, rung, serving_stack, passed_at);


--
-- Name: uq_quest_lifecycle_archive_once; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_quest_lifecycle_archive_once ON public.quest_lifecycle_events USING btree (quest_id) WHERE (to_state = 'archived'::text);


--
-- Name: uq_report_versions_one_standing; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_report_versions_one_standing ON public.report_versions USING btree (quest_id) WHERE standing;


--
-- Name: chunks fk_chunks_source; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chunks
    ADD CONSTRAINT fk_chunks_source FOREIGN KEY (source_id, user_id, source_anchorable, snapshot_char_count) REFERENCES public.sources(id, user_id, anchorable, snapshot_char_count);


--
-- Name: chunks fk_chunks_strategy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chunks
    ADD CONSTRAINT fk_chunks_strategy FOREIGN KEY (strategy_id) REFERENCES public.chunk_strategies(id);


--
-- Name: claim_derivations fk_claim_derivations_claim; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_derivations
    ADD CONSTRAINT fk_claim_derivations_claim FOREIGN KEY (claim_id, quest_id) REFERENCES public.claims(id, quest_id);


--
-- Name: claim_derivations fk_claim_derivations_parent; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_derivations
    ADD CONSTRAINT fk_claim_derivations_parent FOREIGN KEY (parent_claim_id, quest_id) REFERENCES public.claims(id, quest_id);


--
-- Name: claim_derivations fk_claim_derivations_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_derivations
    ADD CONSTRAINT fk_claim_derivations_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: claims fk_claims_created_session; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claims
    ADD CONSTRAINT fk_claims_created_session FOREIGN KEY (created_session_id, quest_id) REFERENCES public.sessions(id, quest_id);


--
-- Name: claims fk_claims_origin_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claims
    ADD CONSTRAINT fk_claims_origin_quest FOREIGN KEY (origin_quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: claims fk_claims_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claims
    ADD CONSTRAINT fk_claims_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: conflict_sources fk_conflict_sources_conflict; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conflict_sources
    ADD CONSTRAINT fk_conflict_sources_conflict FOREIGN KEY (conflict_id) REFERENCES public.conflicts(id) ON DELETE CASCADE;


--
-- Name: conflict_sources fk_conflict_sources_source; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conflict_sources
    ADD CONSTRAINT fk_conflict_sources_source FOREIGN KEY (source_id, user_id, source_anchorable) REFERENCES public.sources(id, user_id, anchorable);


--
-- Name: conflicts fk_conflicts_claim; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conflicts
    ADD CONSTRAINT fk_conflicts_claim FOREIGN KEY (claim_id, quest_id) REFERENCES public.claims(id, quest_id);


--
-- Name: conflicts fk_conflicts_created_session; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conflicts
    ADD CONSTRAINT fk_conflicts_created_session FOREIGN KEY (created_session_id, quest_id) REFERENCES public.sessions(id, quest_id);


--
-- Name: conflicts fk_conflicts_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conflicts
    ADD CONSTRAINT fk_conflicts_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: emb_bge_m3_1024 fk_emb_bge_m3_1024_chunk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_bge_m3_1024
    ADD CONSTRAINT fk_emb_bge_m3_1024_chunk FOREIGN KEY (chunk_id, user_id) REFERENCES public.chunks(id, user_id);


--
-- Name: emb_bge_m3_1024 fk_emb_bge_m3_1024_claim; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_bge_m3_1024
    ADD CONSTRAINT fk_emb_bge_m3_1024_claim FOREIGN KEY (claim_id, user_id) REFERENCES public.claims(id, user_id);


--
-- Name: emb_bge_m3_1024 fk_emb_bge_m3_1024_job; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_bge_m3_1024
    ADD CONSTRAINT fk_emb_bge_m3_1024_job FOREIGN KEY (job_id, user_id) REFERENCES public.embed_jobs(id, user_id);


--
-- Name: emb_bge_m3_1024 fk_emb_bge_m3_1024_model; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_bge_m3_1024
    ADD CONSTRAINT fk_emb_bge_m3_1024_model FOREIGN KEY (model_id, model_status) REFERENCES public.embedding_models(id, status);


--
-- Name: emb_bge_m3_1024 fk_emb_bge_m3_1024_need; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_bge_m3_1024
    ADD CONSTRAINT fk_emb_bge_m3_1024_need FOREIGN KEY (need_id, user_id) REFERENCES public.frontier_entries(id, user_id);


--
-- Name: emb_minilm_ab_384 fk_emb_minilm_ab_384_chunk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_minilm_ab_384
    ADD CONSTRAINT fk_emb_minilm_ab_384_chunk FOREIGN KEY (chunk_id, user_id) REFERENCES public.chunks(id, user_id);


--
-- Name: emb_minilm_ab_384 fk_emb_minilm_ab_384_claim; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_minilm_ab_384
    ADD CONSTRAINT fk_emb_minilm_ab_384_claim FOREIGN KEY (claim_id, user_id) REFERENCES public.claims(id, user_id);


--
-- Name: emb_minilm_ab_384 fk_emb_minilm_ab_384_job; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_minilm_ab_384
    ADD CONSTRAINT fk_emb_minilm_ab_384_job FOREIGN KEY (job_id, user_id) REFERENCES public.embed_jobs(id, user_id);


--
-- Name: emb_minilm_ab_384 fk_emb_minilm_ab_384_model; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_minilm_ab_384
    ADD CONSTRAINT fk_emb_minilm_ab_384_model FOREIGN KEY (model_id, model_status) REFERENCES public.embedding_models(id, status);


--
-- Name: emb_minilm_ab_384 fk_emb_minilm_ab_384_need; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emb_minilm_ab_384
    ADD CONSTRAINT fk_emb_minilm_ab_384_need FOREIGN KEY (need_id, user_id) REFERENCES public.frontier_entries(id, user_id);


--
-- Name: embed_jobs fk_embed_jobs_model; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embed_jobs
    ADD CONSTRAINT fk_embed_jobs_model FOREIGN KEY (model_id) REFERENCES public.embedding_models(id);


--
-- Name: embed_jobs fk_embed_jobs_phase; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embed_jobs
    ADD CONSTRAINT fk_embed_jobs_phase FOREIGN KEY (phase_id, quest_id) REFERENCES public.phases(id, quest_id);


--
-- Name: embed_jobs fk_embed_jobs_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embed_jobs
    ADD CONSTRAINT fk_embed_jobs_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: embed_jobs fk_embed_jobs_source; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embed_jobs
    ADD CONSTRAINT fk_embed_jobs_source FOREIGN KEY (source_id, user_id) REFERENCES public.sources(id, user_id);


--
-- Name: embed_jobs fk_embed_jobs_strategy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embed_jobs
    ADD CONSTRAINT fk_embed_jobs_strategy FOREIGN KEY (strategy_id) REFERENCES public.chunk_strategies(id);


--
-- Name: embed_jobs fk_embed_jobs_usage; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embed_jobs
    ADD CONSTRAINT fk_embed_jobs_usage FOREIGN KEY (usage_event_id, user_id) REFERENCES public.usage_events(id, user_id);


--
-- Name: embed_jobs fk_embed_jobs_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embed_jobs
    ADD CONSTRAINT fk_embed_jobs_user FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: evidence fk_evidence_created_session; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT fk_evidence_created_session FOREIGN KEY (created_session_id, quest_id) REFERENCES public.sessions(id, quest_id);


--
-- Name: evidence_edges fk_evidence_edges_claim; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence_edges
    ADD CONSTRAINT fk_evidence_edges_claim FOREIGN KEY (claim_id, quest_id) REFERENCES public.claims(id, quest_id);


--
-- Name: evidence_edges fk_evidence_edges_evidence; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence_edges
    ADD CONSTRAINT fk_evidence_edges_evidence FOREIGN KEY (evidence_id, quest_id) REFERENCES public.evidence(id, quest_id);


--
-- Name: evidence_edges fk_evidence_edges_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence_edges
    ADD CONSTRAINT fk_evidence_edges_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: evidence fk_evidence_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT fk_evidence_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: evidence fk_evidence_source; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT fk_evidence_source FOREIGN KEY (source_id, user_id, source_anchorable, snapshot_char_count) REFERENCES public.sources(id, user_id, anchorable, snapshot_char_count);


--
-- Name: frontier_entries fk_frontier_claim; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.frontier_entries
    ADD CONSTRAINT fk_frontier_claim FOREIGN KEY (claim_id, quest_id) REFERENCES public.claims(id, quest_id);


--
-- Name: frontier_entries fk_frontier_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.frontier_entries
    ADD CONSTRAINT fk_frontier_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: frontier_entries fk_frontier_spawned_phase; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.frontier_entries
    ADD CONSTRAINT fk_frontier_spawned_phase FOREIGN KEY (spawned_by_phase_id, quest_id) REFERENCES public.phases(id, quest_id);


--
-- Name: phases fk_phases_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phases
    ADD CONSTRAINT fk_phases_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: quest_lifecycle_events fk_qle_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_lifecycle_events
    ADD CONSTRAINT fk_qle_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: quest_lifecycle_events fk_quest_lifecycle_verification; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_lifecycle_events
    ADD CONSTRAINT fk_quest_lifecycle_verification FOREIGN KEY (verification_phase_id, quest_id, verification_phase_kind, verification_phase_state) REFERENCES public.phases(id, quest_id, kind, state);


--
-- Name: quest_sources fk_quest_sources_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_sources
    ADD CONSTRAINT fk_quest_sources_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: quest_sources fk_quest_sources_source; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_sources
    ADD CONSTRAINT fk_quest_sources_source FOREIGN KEY (source_id, user_id) REFERENCES public.sources(id, user_id);


--
-- Name: quests fk_quests_source_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quests
    ADD CONSTRAINT fk_quests_source_quest FOREIGN KEY (source_quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: quests fk_quests_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quests
    ADD CONSTRAINT fk_quests_user FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: report_citations fk_report_citations_import_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_citations
    ADD CONSTRAINT fk_report_citations_import_quest FOREIGN KEY (import_source_quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: report_citations fk_report_citations_imported_source; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_citations
    ADD CONSTRAINT fk_report_citations_imported_source FOREIGN KEY (imported_source_id, imported_source_anchorable) REFERENCES public.sources(id, anchorable);


--
-- Name: report_citations fk_report_citations_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_citations
    ADD CONSTRAINT fk_report_citations_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: report_citations fk_report_citations_report; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_citations
    ADD CONSTRAINT fk_report_citations_report FOREIGN KEY (report_version_id, quest_id) REFERENCES public.report_versions(id, quest_id);


--
-- Name: report_citations fk_report_citations_source; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_citations
    ADD CONSTRAINT fk_report_citations_source FOREIGN KEY (source_id, user_id, source_anchorable) REFERENCES public.sources(id, user_id, anchorable);


--
-- Name: report_versions fk_report_versions_phase; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_versions
    ADD CONSTRAINT fk_report_versions_phase FOREIGN KEY (synthesis_phase_id, quest_id, synthesis_phase_kind) REFERENCES public.phases(id, quest_id, kind);


--
-- Name: report_versions fk_report_versions_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_versions
    ADD CONSTRAINT fk_report_versions_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: report_versions fk_report_versions_session; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_versions
    ADD CONSTRAINT fk_report_versions_session FOREIGN KEY (created_session_id, synthesis_phase_id) REFERENCES public.sessions(id, phase_id);


--
-- Name: resource_grants fk_resource_grants_grantee_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_grants
    ADD CONSTRAINT fk_resource_grants_grantee_user FOREIGN KEY (grantee_user_id) REFERENCES public.users(id);


--
-- Name: resource_grants fk_resource_grants_grantee_workspace; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_grants
    ADD CONSTRAINT fk_resource_grants_grantee_workspace FOREIGN KEY (grantee_workspace_id) REFERENCES public.workspaces(id);


--
-- Name: resource_grants fk_resource_grants_owner; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_grants
    ADD CONSTRAINT fk_resource_grants_owner FOREIGN KEY (owner_user_id) REFERENCES public.users(id);


--
-- Name: resource_grants fk_resource_grants_source; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_grants
    ADD CONSTRAINT fk_resource_grants_source FOREIGN KEY (source_id, owner_user_id) REFERENCES public.sources(id, user_id);


--
-- Name: sessions fk_sessions_phase; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_sessions_phase FOREIGN KEY (phase_id, quest_id) REFERENCES public.phases(id, quest_id);


--
-- Name: sessions fk_sessions_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_sessions_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: sources fk_sources_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT fk_sources_user FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: tool_calls fk_tool_calls_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_calls
    ADD CONSTRAINT fk_tool_calls_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: tool_calls fk_tool_calls_session; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_calls
    ADD CONSTRAINT fk_tool_calls_session FOREIGN KEY (session_id, quest_id) REFERENCES public.sessions(id, quest_id);


--
-- Name: usage_events fk_usage_phase; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events
    ADD CONSTRAINT fk_usage_phase FOREIGN KEY (phase_id, quest_id) REFERENCES public.phases(id, quest_id);


--
-- Name: usage_events fk_usage_quest; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events
    ADD CONSTRAINT fk_usage_quest FOREIGN KEY (quest_id, user_id) REFERENCES public.quests(id, user_id);


--
-- Name: usage_events fk_usage_session; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events
    ADD CONSTRAINT fk_usage_session FOREIGN KEY (session_id, phase_id) REFERENCES public.sessions(id, phase_id);


--
-- Name: usage_events fk_usage_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events
    ADD CONSTRAINT fk_usage_user FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: workspace_members fk_workspace_members_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_members
    ADD CONSTRAINT fk_workspace_members_user FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: workspace_members fk_workspace_members_workspace; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_members
    ADD CONSTRAINT fk_workspace_members_workspace FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: workspaces fk_workspaces_creator; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT fk_workspaces_creator FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--


SET search_path TO "$user", public;

INSERT INTO schema_migrations (filename) VALUES
('20261030000000_create_users.rb'),
('20261030000100_create_documents.rb'),
('20261124000001_drop_substrate_users.rb'),
('20261124000002_create_core_model_i01.rb'),
('20261124000003_add_cross_quest_i02.rb'),
('20261124000004_add_retrieval_i03.rb'),
('20261124000005_add_ladder_passes.rb'),
('20261124000006_add_users_auth_columns.rb'),
('20261124000007_add_quest_process_config_tables.rb');
