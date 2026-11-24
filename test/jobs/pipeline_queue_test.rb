# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/pipeline_fixtures"

# The ONE queue, ONE worker, MANY bodies: the delegate routes the embed
# pipeline's payloads through the pipeline and STILL routes the substrate's
# document payloads unchanged.
class PipelineQueueTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @mock = MockEmbeddingsServer.new.start
  end

  def teardown
    @mock&.stop
    PipelineFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  def test_delegate_routes_embed_job_id_through_the_pipeline
    tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = tenancy[:user_id]
    PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: tenancy[:quest_id], seq: 1,
      text: "queued through the delegate")
    PipelineFixtures.register_test_model(conn, @mock)
    @mock.script([{type: :embeddings, vectors: [[0.0] + Array.new(PipelineFixtures::MINILM_DIMS - 1, 0.0)],
      usage: {prompt_tokens: 2, total_tokens: 2}}])
    job_id = PipelineFixtures.mint_embed_job(conn, user_id: @user_id, quest_id: tenancy[:quest_id],
      phase_id: tenancy[:phase_id], kind: "embed", model_id: PipelineFixtures::MINILM_MODEL_ID,
      target_kind: "claim",
      idem_key: "embed:#{PipelineFixtures::MINILM_MODEL_ID}:claim:quest:#{tenancy[:quest_id]}")

    # The container's queue is the Inline processor under test env — the
    # delegate runs the pipeline body in-request.
    Sync do
      Kquest::App["job_queue"].call({"embed_job_id" => job_id})
    end

    job = conn[:embed_jobs].where(id: job_id).first
    assert_equal "complete", job[:state]
    assert_equal 1, conn[PipelineFixtures::MINILM_TABLE.to_sym].where(job_id: job_id).count
    refute_nil job[:usage_event_id]
    assert_equal 1, @mock.captured_requests.size
  end

  def test_delegate_still_routes_document_id_through_the_substrate_body
    Faker::Internet.unique.clear
    content = "delegated document bytes\n"
    data = Kquest::AttachmentUploader.store(StringIO.new(content))
    document = Factory[:document, attachment_data: data]

    Sync do
      Kquest::App["job_queue"].call({"document_id" => document.id})
    end

    reloaded = Kquest::Repos::DocumentsRepo.new.by_pk(document.id)
    assert_equal content.bytesize, reloaded.byte_count
    refute_nil reloaded.processed_at
  end
end
