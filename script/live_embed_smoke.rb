#!/usr/bin/env ruby
# frozen_string_literal: true

# The ONE named live-key smoke (I12 AC3): the real wire, END-TO-END through
# the landed pipeline — registry row → admission → fast-embeddings 0.1.1 →
# vector row → J-SPEND — never a bare probe.
#
# Key handling (BRIEF §9 — paths, never contents): the key is read from
# KQUEST_SMOKE_KEY_PATH or ~/.kb-openrouter-key and bound to
# ENV["OPENROUTER_API_KEY"] for THIS process only (the deployment's job,
# never the repo's). Contents are never printed, never committed.
#
# Pinned skip semantics — the gate can neither silently pass without a key
# nor fail a keyless machine:
#   key file absent → print LIVE_SMOKE_SKIPPED_NO_KEY, exit 0 (a LOUD skip)
#   success         → print LIVE_SMOKE_OK, ONLY behind the full assertion chain
#   anything else   → exit 1, no marker
#
# Idempotent fixed-uuid fixtures, cleaned at start (reruns safe). One chunk
# ≈ $5e-8. NEVER a CI job.

KEY_PATH = ENV["KQUEST_SMOKE_KEY_PATH"] || File.expand_path("~/.kb-openrouter-key")

unless KEY_PATH && File.exist?(KEY_PATH)
  puts "LIVE_SMOKE_SKIPPED_NO_KEY"
  exit 0
end

require "bundler/setup"
require "hanami/prepare"
require "kernel/sync"

# The smoke's own process binds the key from the file — the deployment's job.
ENV["OPENROUTER_API_KEY"] = File.read(KEY_PATH).strip

USER_ID     = "61000000-0000-4000-8000-000000000001"
QUEST_ID    = "61000000-0000-4000-8000-000000000002"
PHASE_ID    = "61000000-0000-4000-8000-000000000003"
SESSION_ID  = "61000000-0000-4000-8000-000000000004"
STRATEGY_ID = "61000000-0000-4000-8000-000000000005"
# Pinned by emb_bge_m3_1024's CHECK (model_id = 92000000-…-0001).
MODEL_ID    = "92000000-0000-4000-8000-000000000001"

conn = Kquest::App["db.gateway"].connection

# ---- clean the fixed-uuid fixtures at start (reverse-FK order) -------------
conn[:emb_bge_m3_1024].where(user_id: USER_ID).delete
conn[:embed_jobs].where(user_id: USER_ID).delete
conn[:usage_events].where(user_id: USER_ID).delete
conn[:chunks].where(user_id: USER_ID).delete
conn[:quest_sources].where(user_id: USER_ID).delete
conn[:sources].where(user_id: USER_ID).delete
conn[:sessions].where(id: SESSION_ID).delete
conn[:phases].where(id: PHASE_ID).delete
conn[:quests].where(id: QUEST_ID).delete
conn[:users].where(id: USER_ID).delete
conn[:chunk_strategies].where(id: STRATEGY_ID).delete
conn[:embedding_models].where(id: MODEL_ID).delete
# ---- the D10 chain + the registry row (data, as in the I03 seed) -----------
now = Time.now
conn[:users].insert(id: USER_ID, handle: "i12-smoke", github_uid: "i12-smoke-uid", username: "i12-smoke")
conn[:quests].insert(id: QUEST_ID, user_id: USER_ID, topic: "I12 live embed smoke",
  web_call_budget: 0, token_budget: 0, spend_budget_usd: 1.0)
conn[:phases].insert(id: PHASE_ID, user_id: USER_ID, quest_id: QUEST_ID, kind: "decompose",
  state: "complete", started_at: now)
conn[:sessions].insert(id: SESSION_ID, user_id: USER_ID, quest_id: QUEST_ID, phase_id: PHASE_ID,
  mode: "autonomous", driver: "orchestrator", model: "bge-m3",
  transcript_blob_key: "sessions/#{SESSION_ID}/transcript.jsonl", started_at: now)
# The para-800 row is CONFIG data and the db may already carry one (the
# suite's tests mint the same row; uq_chunk_strategies_name_version) —
# find-or-create by (name, version).
strategy_id = conn[:chunk_strategies].where(name: "para-800", version: 1).get(:id)
strategy_id ||= conn[:chunk_strategies].insert(id: STRATEGY_ID, name: "para-800", version: 1,
  target_chars: 800, overlap_chars: 0, paragraph_aligned: true)

conn[:embedding_models].insert(
  id: MODEL_ID, slug: "bge-m3-1024", wire_name: "bge-m3", provider: "openrouter",
  endpoint: "https://openrouter.ai/api/v1/embeddings", api_key_ref: "env:OPENROUTER_API_KEY",
  dimensions: 1024, metric: "cosine", batch_max_texts: 64, input_max_chars: 8192,
  status: "active", table_name: "emb_bge_m3_1024", registered_at: now
)

# ---- the pipeline round ----------------------------------------------------
fetched = Kquest::Pipeline::FetchBody.call(
  user_id: USER_ID, url: "https://fixture.example/i12-live-smoke",
  title: "I12 live embed smoke", role: "citable",
  snapshot_text: "The live smoke chunk: a short fixture paragraph about t-statistics and standard errors.\n",
  raw_body: "raw-envelope:i12-smoke", quest_id: QUEST_ID, phase_id: PHASE_ID, conn: conn
)

chunk_result = Kquest::Pipeline::Enqueue.chunk(strategy_id: strategy_id, quest_id: QUEST_ID,
  user_id: USER_ID, phase_id: PHASE_ID)
chunk_job = conn[:embed_jobs].where(id: chunk_result[:id]).first
raise "chunk job did not complete: #{chunk_job[:state]} / #{chunk_job[:error_note].inspect}" unless chunk_job[:state] == "complete"

embed_result = Kquest::Pipeline::Enqueue.embed(model_id: MODEL_ID, target_kind: "chunk",
  strategy_id: strategy_id, quest_id: QUEST_ID, user_id: USER_ID, phase_id: PHASE_ID)
embed_job = conn[:embed_jobs].where(id: embed_result[:id]).first

# ---- the assertion chain (LIVE_SMOKE_OK is printed only behind ALL of it) --
raise "embed job not complete: #{embed_job[:state]} / #{embed_job[:error_note].inspect}" unless embed_job[:state] == "complete"

vector = conn[:emb_bge_m3_1024].where(job_id: embed_result[:id]).first
raise "no vector row for the smoke job" unless vector
dims = conn.fetch("SELECT vector_dims(embedding) AS d FROM emb_bge_m3_1024 WHERE job_id = ?",
  embed_result[:id]).first[:d].to_i
raise "expected 1024 dims, got #{dims}" unless dims == 1024

chunk_row = conn[:chunks].where(id: vector[:chunk_id]).first
raise "embedded_text does not byte-match the chunk" unless vector[:embedded_text] == chunk_row[:text]

spend = conn[:usage_events].where(id: embed_job[:usage_event_id]).first
raise "no spend row linked" unless spend
raise "spend kind #{spend[:kind].inspect}" unless spend[:kind] == "embedding"
raise "spend off the D10 chain" unless [spend[:user_id], spend[:quest_id], spend[:phase_id], spend[:session_id]] ==
                                       [USER_ID, QUEST_ID, PHASE_ID, SESSION_ID]
raise "input_tokens not positive: #{spend[:input_tokens]}" unless spend[:input_tokens] > 0

puts "dims=#{dims} input_tokens=#{spend[:input_tokens]} model=#{spend[:model]}"
puts "LIVE_SMOKE_OK"
