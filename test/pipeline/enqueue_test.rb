# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/pipeline_fixtures"

# The caller-side mint: the seed's example key forms, idempotency, the
# failed-key exemption, and the full Inline round.
class EnqueueTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @mock = MockEmbeddingsServer.new.start
  end

  def teardown
    @mock&.stop
    PipelineFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  def test_mint_determinism_and_idempotent_re_enqueue
    @tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @tenancy[:quest_id], seq: 1, text: "one claim")
    PipelineFixtures.register_test_model(conn, @mock)
    @mock.script([{type: :embeddings, vectors: [vec0], usage: {prompt_tokens: 1, total_tokens: 1}}])

    model = PipelineFixtures::MINILM_MODEL_ID
    qid = @tenancy[:quest_id]
    first = Kquest::Pipeline::Enqueue.embed(model_id: model, target_kind: "claim", quest_id: qid,
      user_id: @user_id, phase_id: @tenancy[:phase_id])
    assert_equal :created, first[:status]

    # The seed's example key form, verbatim.
    assert_equal 1, conn[:embed_jobs].where(idem_key: "embed:#{model}:claim:quest:#{qid}").count

    again = Kquest::Pipeline::Enqueue.embed(model_id: model, target_kind: "claim", quest_id: qid,
      user_id: @user_id, phase_id: @tenancy[:phase_id])
    assert_equal :noop, again[:status] # the first enqueue COMPLETED it in-request
    assert_equal first[:id], again[:id]
    assert_equal 1, conn[:embed_jobs].where(user_id: @user_id, kind: "embed").count

    # The chunk-family key forms, verbatim: quest- and src-scoped.
    strategy_id = PipelineFixtures.mint_strategy(conn)
    source = Kquest::Pipeline::FetchBody.call(user_id: @user_id, url: "https://fixture.example/enqueue-src",
      title: "Enqueue src fixture", role: "citable", snapshot_text: "chunkable text\n",
      raw_body: "raw", quest_id: qid, conn: conn)
    quest_chunk = Kquest::Pipeline::Enqueue.chunk(strategy_id: strategy_id, quest_id: qid, user_id: @user_id)
    assert_equal :created, quest_chunk[:status]
    assert conn[:embed_jobs].where(idem_key: "chunk:#{strategy_id}:quest:#{qid}").first
    src_chunk = Kquest::Pipeline::Enqueue.chunk(strategy_id: strategy_id, quest_id: qid, user_id: @user_id,
      source_id: source[:source_id])
    assert_equal :created, src_chunk[:status]
    assert conn[:embed_jobs].where(idem_key: "chunk:#{strategy_id}:src:#{source[:source_id]}").first
    # need-family form (frontier_need) via the embed mint:
    need = Kquest::Pipeline::Enqueue.embed(model_id: model, target_kind: "frontier_need", quest_id: qid,
      user_id: @user_id, phase_id: @tenancy[:phase_id])
    assert_equal :created, need[:status]
    assert conn[:embed_jobs].where(idem_key: "embed:#{model}:need:quest:#{qid}").first
  end

  def test_failed_attempts_do_not_pin_the_key
    @tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @tenancy[:quest_id], seq: 1, text: "retry claim")
    PipelineFixtures.register_test_model(conn, @mock)
    @mock.script([{type: :embeddings, vectors: [vec0], usage: {prompt_tokens: 1, total_tokens: 1}}])
    model = PipelineFixtures::MINILM_MODEL_ID
    key = "embed:#{model}:claim:quest:#{@tenancy[:quest_id]}"

    # The seed's j08→j07 law: a failed row sharing the key does not block.
    failed_id = PipelineFixtures.mint_embed_job(conn, user_id: @user_id, quest_id: @tenancy[:quest_id],
      phase_id: @tenancy[:phase_id], kind: "embed", model_id: model, target_kind: "claim",
      idem_key: key, state: "failed")
    assert_equal "failed", conn[:embed_jobs].where(id: failed_id).first[:state]

    retry_result = Kquest::Pipeline::Enqueue.embed(model_id: model, target_kind: "claim",
      quest_id: @tenancy[:quest_id], user_id: @user_id, phase_id: @tenancy[:phase_id])

    assert_equal :created, retry_result[:status]
    refute_equal failed_id, retry_result[:id]
    assert_equal 2, conn[:embed_jobs].where(idem_key: key).count # failed + the new attempt
    assert_equal "complete", conn[:embed_jobs].where(id: retry_result[:id]).first[:state]
  end

  def test_enqueue_through_the_inline_queue_completes_end_to_end
    @tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @tenancy[:quest_id], seq: 1,
      text: "the full enqueue-queue-runner-wire-ledger round")
    PipelineFixtures.register_test_model(conn, @mock)
    @mock.script([{type: :embeddings, vectors: [vec0], usage: {prompt_tokens: 4, total_tokens: 4}}])

    result = Kquest::Pipeline::Enqueue.embed(model_id: PipelineFixtures::MINILM_MODEL_ID,
      target_kind: "claim", quest_id: @tenancy[:quest_id], user_id: @user_id,
      phase_id: @tenancy[:phase_id])

    assert_equal :created, result[:status]
    job = conn[:embed_jobs].where(id: result[:id]).first
    assert_equal "complete", job[:state] # the Inline processor ran it in-request
    assert_equal 1, conn[PipelineFixtures::MINILM_TABLE.to_sym].where(job_id: job[:id]).count
    spend = conn[:usage_events].where(id: job[:usage_event_id]).first
    refute_nil spend
    assert_equal 4, spend[:input_tokens]
    assert_equal 1, @mock.captured_requests.size
  end

  def vec0
    @vec0 ||= [0.0] + Array.new(PipelineFixtures::MINILM_DIMS - 1, 0.0)
  end
end
