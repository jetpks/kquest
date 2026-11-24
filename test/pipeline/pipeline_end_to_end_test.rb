# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/pipeline_fixtures"

# The whole pipeline over the ledger: fetch → chunk (the para-800 strategy
# row) → embed (chunk-family, strategy-scoped), one wire call carrying every
# chunk text in registry order, embedded_text == chunks.text (L1 survives
# the pipeline).
class PipelineEndToEndTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @mock = MockEmbeddingsServer.new.start
  end

  def teardown
    @mock&.stop
    PipelineFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  def test_fetch_chunk_embed_over_the_ledger
    @tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    qid = @tenancy[:quest_id]
    snapshot = ["Paragraph one of the end-to-end fixture text.",
      "Paragraph two of the end-to-end fixture text.",
      "Paragraph three of the end-to-end fixture text."]
      .map { |p| (p + " " + "filler " * 60 + "\n") }

    # fetch (fixture-injected — the network leg is ENTRY 3's)
    fetched = Kquest::Pipeline::FetchBody.call(user_id: @user_id,
      url: "https://fixture.example/e2e", title: "End-to-end fixture", role: "citable",
      snapshot_text: snapshot.join, raw_body: "raw:e2e", quest_id: qid, conn: conn)
    assert_equal true, fetched[:created]

    # chunk (the para-800 strategy ROW's data)
    strategy_id = PipelineFixtures.mint_strategy(conn, name: "para-800")
    chunk_result = Kquest::Pipeline::Enqueue.chunk(strategy_id: strategy_id, quest_id: qid, user_id: @user_id,
      phase_id: @tenancy[:phase_id])
    assert_equal :created, chunk_result[:status]
    chunk_texts = conn[:chunks].where(strategy_id: strategy_id).order(:source_id, :ordinal).select_map(:text)
    assert_operator chunk_texts.size, :>=, 2

    # embed (chunk-family, strategy-scoped — the seed's key form)
    PipelineFixtures.register_test_model(conn, @mock, batch_max_texts: 64)
    @mock.script([{type: :embeddings,
      vectors: Array.new(chunk_texts.size) { [0.0] + Array.new(PipelineFixtures::MINILM_DIMS - 1, 0.0) },
      usage: {prompt_tokens: chunk_texts.size * 2, total_tokens: chunk_texts.size * 2}}])
    embed_result = Kquest::Pipeline::Enqueue.embed(model_id: PipelineFixtures::MINILM_MODEL_ID,
      target_kind: "chunk", strategy_id: strategy_id, quest_id: qid, user_id: @user_id,
      phase_id: @tenancy[:phase_id])
    assert_equal :created, embed_result[:status]

    # ONE wire call carrying EVERY chunk text in registry (source_id, ordinal) order.
    requests = @mock.captured_requests
    assert_equal 1, requests.size
    assert_equal chunk_texts, requests[0]["input"]

    # embedded_text byte-matches chunks.text — L1 survives the pipeline.
    vectors = conn[PipelineFixtures::MINILM_TABLE.to_sym].where(job_id: embed_result[:id]).all
    assert_equal chunk_texts.size, vectors.size
    chunk_rows = conn[:chunks].where(strategy_id: strategy_id).order(:source_id, :ordinal).all
    vectors.each_with_index do |v, i|
      assert_equal chunk_rows[i][:id], v[:chunk_id]
      assert_equal chunk_rows[i][:text], v[:embedded_text]
      assert_equal "chunk", v[:target_kind]
    end

    # The ledger: chunk job complete with NO usage row; embed job complete
    # with its J-SPEND row on the D10 chain.
    chunk_job = conn[:embed_jobs].where(id: chunk_result[:id]).first
    assert_equal "complete", chunk_job[:state]
    assert_nil chunk_job[:usage_event_id]
    embed_job = conn[:embed_jobs].where(id: embed_result[:id]).first
    assert_equal "complete", embed_job[:state]
    spend = conn[:usage_events].where(id: embed_job[:usage_event_id]).first
    refute_nil spend
    assert_equal "embedding", spend[:kind]
    assert_equal chunk_texts.size * 2, spend[:input_tokens]
    assert_equal @tenancy[:session_id], spend[:session_id]
  end
end
