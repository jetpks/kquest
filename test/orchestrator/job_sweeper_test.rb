# frozen_string_literal: true

require_relative "../test_helper"
require "async"
require_relative "../support/orchestrator_fixtures"
require_relative "../support/pipeline_fixtures"
require_relative "../../lib/kquest/orchestrator/job_sweeper"
require_relative "../../lib/kquest/orchestrator/worker_registry"
require_relative "../../lib/kquest/engine/session_supervisor"

# The job sweeper (I08 §2.3): orphaned `running` embed rows resume from
# `done_items` (re-enqueued — J-IDEM) or mark failed with the error pair
# (ck_embed_jobs_error_pair) when the resume is impossible; the singleton
# job worker's boot-time sweep is honest (no live job worker ⇒ every running
# row is orphaned; a live one claims them all).
class JobSweeperTest < Minitest::Test
  def setup
    # Self-healing model row (the I16 71069b0 law — the 3rd order-dependent
    # flake of the class, caught post-I20-integration): the sweeper's
    # fixtures reference the MINILM model row the EMBED-PIPELINE tests
    # register; under parallel scheduling this file can run before any of
    # them and fk_embed_jobs_model bites. The sweeper never calls the wire —
    # an inert endpoint suffices.
    if conn[:embedding_models].where(id: PipelineFixtures::MINILM_MODEL_ID).empty?
      conn[:embedding_models].insert(
        id: PipelineFixtures::MINILM_MODEL_ID, slug: "minilm-ab-384",
        wire_name: "mock-embed-#{PipelineFixtures::MINILM_DIMS}", provider: "mock",
        endpoint: "http://localhost:9/vitro/embeddings", api_key_ref: nil,
        dimensions: PipelineFixtures::MINILM_DIMS, metric: "cosine",
        batch_max_texts: 64, input_max_chars: 8192, status: "active",
        retired_at: nil, table_name: PipelineFixtures::MINILM_TABLE,
        registered_at: Time.now)
    end
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    @quest_id = @tenancy[:quest_id]
    @phase_id = conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "decompose")
    # The spend chain (the embed body's law: user→quest→phase→session total).
    conn[:sessions].insert(user_id: @user_id, quest_id: @quest_id, phase_id: @phase_id,
                           mode: "autonomous", driver: "orchestrator", model: "test-model")
    @prefix = OrchestratorFixtures.redis_prefix
    @redis = OrchestratorFixtures.redis_client
  end

  def teardown
    Sync { OrchestratorFixtures.cleanup_redis(@redis, @prefix) } if @redis
    @redis&.close
    OrchestratorFixtures.cleanup(conn, user_id: @user_id)
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def registry(kind: "job")
    Kquest::Orchestrator::WorkerRegistry.new(redis: @redis, kind: kind, prefix: @prefix)
  end

  def sweeper(reg) = Kquest::Orchestrator::JobSweeper.new(conn: conn, registry: reg)

  BGE_MODEL_ID = "92000000-0000-4000-8000-000000000001" # the seeded D4 row

  def mint_running_job(state: "running", model_id: BGE_MODEL_ID, total_items: 5, done_items: 3)
    conn[:embed_jobs].insert(
      user_id: @user_id, quest_id: @quest_id, phase_id: @phase_id, kind: "embed",
      model_id: model_id, target_kind: "claim", state: state,
      idem_key: "embed:sweep-test:claim:#{SecureRandom.hex(4)}",
      total_items: total_items, done_items: done_items, started_at: Time.now
    )
  end

  # One claim target for the embed body (the target set the cursor reads).
  def mint_sweeper_claim
    seq = (conn[:claims].where(quest_id: @quest_id).max(:quest_seq) || 0) + 1
    conn[:claims].insert(user_id: @user_id, quest_id: @quest_id, quest_seq: seq,
                         text: "sweeper probe claim",
                         urn: "kb:claim:" + Kquest::Pipeline::Base58.encode(
                           Digest::SHA256.digest("#{@quest_id}sweeper probe claim"))[0, 10])
  end

  def test_orphaned_running_rows_resume_from_done_items
    PipelineFixtures.register_test_model(conn, Struct.new(:url).new("http://127.0.0.1:1"))
    job_id = mint_running_job(model_id: PipelineFixtures::MINILM_MODEL_ID,
                              total_items: 1, done_items: 1)
    mint_sweeper_claim
    # The registry is a stub-free seam: NO live job worker exists (nothing
    # registered), so the row is orphaned by construction. The re-enqueued
    # body RESUMES at the done_items cursor (the one target is already done)
    # and completes WITHOUT a wire call — the dead endpoint is never touched.
    result = Sync { sweeper(registry).sweep }

    assert_includes result[:resumed], job_id
    row = conn[:embed_jobs].where(id: job_id).first
    assert_equal "complete", row[:state], "the body resumed at the done_items cursor"
    assert_equal 1, row[:done_items], "the done_items cursor survived (J-IDEM)"
    assert_nil row[:error_note], "the wire was never touched (a completed cursor resume spends nothing)" 
  ensure
    conn[:embed_jobs].where(id: job_id).delete if job_id
  end

  def test_live_job_worker_claims_its_running_rows
    job_id = mint_running_job
    reg = registry
    reg.register!

    result = Sync { sweeper(reg).sweep }
    assert_empty result[:resumed]
    assert_empty result[:failed]
    assert_equal "running", conn[:embed_jobs].where(id: job_id).get(:state),
                 "a claimed row is untouched"
  ensure
    Sync { reg.unregister! } if reg
    conn[:embed_jobs].where(id: job_id).delete if job_id
  end

  def test_failed_resume_marks_failed_with_the_error_pair
    # The resume is impossible: the re-enqueued body raises (a claim target
    # whose wire endpoint refuses — the model row points at a dead port), so
    # the sweep marks the row failed with the error pair
    # (ck_embed_jobs_error_pair: started_at/ended_at/error_note).
    PipelineFixtures.register_test_model(conn, Struct.new(:url).new("http://127.0.0.1:1"))
    job_id = mint_running_job(model_id: PipelineFixtures::MINILM_MODEL_ID,
                              total_items: 1, done_items: 0)
    mint_sweeper_claim

    result = Sync { sweeper(registry).sweep }

    row = conn[:embed_jobs].where(id: job_id).first
    assert_equal "failed", row[:state],
                 "the re-enqueued body hit the dead wire and the ledger never lies"
    refute_nil row[:ended_at], "the error pair (ck_embed_jobs_error_pair)"
    refute_nil row[:error_note]
  ensure
    conn[:embed_jobs].where(id: job_id).delete if job_id
  end

  def test_complete_rows_are_noops
    # A COMPLETE row (ck_embed_jobs_complete_spend: an embed job that
    # completed carries its usage row) — the sweep's state filter never
    # touches it (J-IDEM: complete rows are no-ops).
    session_id = conn[:sessions].insert(user_id: @user_id, quest_id: @quest_id,
                                        phase_id: @phase_id, mode: "autonomous",
                                        driver: "orchestrator", model: "test-model")
    usage_id = SecureRandom.uuid
    conn[:usage_events].insert(id: usage_id, user_id: @user_id, quest_id: @quest_id,
                               phase_id: @phase_id, session_id: session_id, kind: "embedding",
                               model: "test-model", input_tokens: 1, output_tokens: 1)
    done = SecureRandom.uuid
    conn[:embed_jobs].insert(
      id: done, user_id: @user_id, quest_id: @quest_id, phase_id: @phase_id, kind: "embed",
      model_id: PipelineFixtures::MINILM_MODEL_ID, target_kind: "claim",
      state: "complete", idem_key: "embed:sweep-test:done:1", total_items: 2, done_items: 2,
      started_at: Time.now, ended_at: Time.now, usage_event_id: usage_id
    )
    result = Sync { sweeper(registry).sweep }

    assert_empty result[:resumed] & [done]
    assert_empty result[:failed] & [done]
    assert_equal "complete", conn[:embed_jobs].where(id: done).get(:state)
  end

  # F2 (I20 Part 1, the I16-order-proof class): the boot sweep's call in
  # bin/worker.rb is EARLIER than the registry's register! — at boot,
  # pre-register, no live job-worker heartbeat exists, so every `running`
  # embed row is orphaned and resumes from done_items (the file's own
  # comment's story). RED before the fix: register preceded sweep, so the
  # boot sweep saw its OWN heartbeat and structurally no-op'd.
  def test_boot_sweep_wires_before_the_registry_claim
    source = File.read(File.expand_path("../../bin/worker.rb", __dir__))
    sweep = source.index("job_sweeper.sweep")
    register = source.index("sweep_registry.register!")
    refute_nil sweep, "the boot sweep call is present"
    refute_nil register, "the registry claim is present"
    assert_operator sweep, :<, register,
                   "the boot sweep runs BEFORE the registry claim (the singleton " \
                   "class law makes sweep-before-register the honest boot order)"
  end
end
