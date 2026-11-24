# frozen_string_literal: true

require "securerandom"
require "digest"
require_relative "mock_embeddings_server"

# The pipeline suite's fixture mint (all keyless — the mock wire IS the wire).
#
#   PipelineFixtures.mint_tenancy(conn)         → {user_id:, quest_id:, phase_id:, session_id:}
#   PipelineFixtures.mint_session(conn, ...)    → session_id (extra sessions per phase)
#   PipelineFixtures.mint_claim(conn, ...)      → claim_id (URN via the pipeline's own Base58)
#   PipelineFixtures.mint_strategy(conn, ...)   → strategy_id (chunk_strategies ROW data)
#   PipelineFixtures.register_test_model(conn, mock) → the LOCAL registry row pointing
#       the pipeline at the mock — registry data, never code (NULL api_key_ref:
#       a nil key sends no Authorization header). The bge-m3 row stays pristine
#       for the live smoke.
#   PipelineFixtures.mint_embed_job(conn, ...)  → job_id
#   PipelineFixtures.cleanup(conn, user_id:)    → reverse-FK-order teardown. The
#       substrate action tests' setup_db sweeps tables by list; leaked tenancy
#       rows break that sweep with FK violations on DELETE users — EVERY
#       pipeline test's teardown calls this.
module PipelineFixtures
  # Pinned by emb_minilm_ab_384's CHECK (model_id = 92000000-…-0002): the
  # second generated vector table is the LOCAL test target.
  MINILM_MODEL_ID = "92000000-0000-4000-8000-000000000002"
  MINILM_TABLE = "emb_minilm_ab_384"
  MINILM_DIMS = 384

  module_function

  def mint_tenancy(conn, started_at: Time.now)
    user_id = conn[:users].insert(handle: "gh-#{SecureRandom.hex(6)}", github_uid: SecureRandom.uuid,
      username: "u#{SecureRandom.hex(6)}", name: "Pipeline Fixture", created_at: Time.now)
    quest_id = conn[:quests].insert(user_id: user_id, topic: "Pipeline fixture quest #{SecureRandom.hex(4)}",
      web_call_budget: 16, token_budget: 1_000_000, spend_budget_usd: 1.0)
    phase_id = conn[:phases].insert(user_id: user_id, quest_id: quest_id, kind: "decompose")
    session_id = conn[:sessions].insert(user_id: user_id, quest_id: quest_id, phase_id: phase_id,
      mode: "autonomous", driver: "orchestrator", model: "test-model",
      transcript_blob_key: "sessions/#{SecureRandom.uuid}/transcript.jsonl", started_at: started_at)
    {user_id: user_id, quest_id: quest_id, phase_id: phase_id, session_id: session_id}
  end

  def mint_session(conn, user_id:, quest_id:, phase_id:, started_at: Time.now)
    conn[:sessions].insert(user_id: user_id, quest_id: quest_id, phase_id: phase_id,
      mode: "autonomous", driver: "orchestrator", model: "test-model",
      transcript_blob_key: "sessions/#{SecureRandom.uuid}/transcript.jsonl", started_at: started_at)
  end

  # DR-06 (quest-salted claim URN): urn = "kb:claim:" + base58(sha256(quest_id
  # || canonical_text))[0,10]; canonical_text per the GENERATED column's
  # definition (NFC, whitespace-squash, edge-trim) — mirrored here so the
  # fixture text and the row agree.
  def mint_claim(conn, user_id:, quest_id:, seq:, text:, session_id: nil)
    canonical = text.gsub(/[ \t\n\r\f\v]+/, " ")
      .gsub(/\A[ \t\n\r\f\v]+|[ \t\n\r\f\v]+\z/, "")
      .unicode_normalize(:nfc)
    urn = "kb:claim:" + Kquest::Pipeline::Base58
      .encode(Digest::SHA256.digest(quest_id + canonical))[0, 10]
    conn[:claims].insert(user_id: user_id, quest_id: quest_id, quest_seq: seq, text: text, urn: urn,
      created_session_id: session_id)
  end

  def mint_strategy(conn, name: "para-800", target_chars: 800, overlap_chars: 0, paragraph_aligned: true)
    # uq_chunk_strategies_name_version: config rows are SHARED (cleanup never
    # deletes them) — find-or-create by (name, version).
    if (existing = conn[:chunk_strategies].where(name: name, version: 1).first)
      return existing[:id]
    end

    conn[:chunk_strategies].insert(name: name, version: 1, target_chars: target_chars,
      overlap_chars: overlap_chars, paragraph_aligned: paragraph_aligned)
  end

  # The LOCAL test model: registry data pointing the pipeline at the mock.
  # Upsert per test (caps are test data — batch slicing and the admission cap
  # come from this row). endpoint = <mock url>/embeddings — the FULL wire
  # endpoint per I03 seed law; Wire derives the client's parent base_url.
  def register_test_model(conn, mock_server, batch_max_texts: 64, input_max_chars: 8192,
                          status: "active", dims: MINILM_DIMS)
    conn[:embedding_models].where(id: MINILM_MODEL_ID).delete
    conn[:embedding_models].insert(
      id: MINILM_MODEL_ID,
      slug: "minilm-ab-384",
      wire_name: "mock-embed-#{dims}",
      provider: "mock",
      endpoint: "#{mock_server.url}/embeddings",
      api_key_ref: nil,
      dimensions: dims,
      metric: "cosine",
      batch_max_texts: batch_max_texts,
      input_max_chars: input_max_chars,
      status: status,
      retired_at: status == "retired" ? Time.now : nil,
      table_name: MINILM_TABLE,
      registered_at: Time.now
    )
  end

  def mint_embed_job(conn, user_id:, quest_id:, phase_id:, kind: "embed", model_id: nil,
                     target_kind: nil, strategy_id: nil, source_id: nil, idem_key:,
                     state: "pending", done_items: 0, error_note: nil)
    times = {}
    if %w[complete failed].include?(state)
      # ck_embed_jobs_run_pair/end_pair/error_pair: non-pending rows carry
      # started_at; terminal rows carry ended_at; failed rows explain.
      now = Time.now
      times = {started_at: now, ended_at: now, error_note: error_note || "fixture failure"}
    end
    conn[:embed_jobs].insert(
      user_id: user_id, quest_id: quest_id, phase_id: phase_id, kind: kind,
      model_id: model_id, target_kind: target_kind, strategy_id: strategy_id,
      source_id: source_id, state: state, idem_key: idem_key, done_items: done_items,
      **times
    )
  end

  # An n-dim mock vector with distinct values (position-identifiable under
  # the index scrambler).
  def vector(dims = MINILM_DIMS)
    Array.new(dims) { |i| (i % 97) / 97.0 }
  end

  def cleanup(conn, user_id:)
    # Reverse-FK order: tool_calls → vectors → jobs → usage → chunks →
    # membership → sources → frontier → claims → sessions → phases → quests →
    # users. (I13: tool_calls joined the sweep — engine tests' audit rows FK
    # onto sessions; leaked rows break the whole suite with FK violations on
    # DELETE users.) The three engine CONFIG tables are global (no user_id
    # column): the sweep resets them to empty — every consumer upserts its
    # own rows, and the seeds' delete+insert law re-heals them at the next
    # `hanami db prepare`.
    conn[:tool_calls].where(user_id: user_id).delete
    conn[:quest_lifecycle_events].where(user_id: user_id).delete
    conn[:emb_minilm_ab_384].where(user_id: user_id).delete
    conn[:emb_bge_m3_1024].where(user_id: user_id).delete
    conn[:embed_jobs].where(user_id: user_id).delete
    conn[:usage_events].where(user_id: user_id).delete
    conn[:chunks].where(user_id: user_id).delete
    conn[:quest_sources].where(user_id: user_id).delete
    conn[:sources].where(user_id: user_id).delete
    conn[:frontier_entries].where(user_id: user_id).delete
    conn[:claims].where(user_id: user_id).delete
    conn[:sessions].where(user_id: user_id).delete
    conn[:phases].where(user_id: user_id).delete
    conn[:quests].where(user_id: user_id).delete
    conn[:users].where(id: user_id).delete
    # The engine config tables (global config data — see the note above).
    conn[:llm_providers].delete
    conn[:engine_config].delete
    conn[:subagent_profiles].delete
    # I14's two lane-authored config tables (global config data, the same
    # law): every consumer upserts its own rows; the seeds' delete+insert
    # re-heals at the next `hanami db prepare`.
    conn[:tool_config].delete
    conn[:web_providers].delete
    nil
  end
end
