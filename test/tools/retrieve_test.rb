# frozen_string_literal: true

require_relative "texts_test"
require_relative "../support/mock_embeddings_server"

# retrieve — hybrid dense+FTS, RRF fusion; NO model parameter EVER.
class RetrieveTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/retrieve.md", __dir__)

  def setup
    mint
    @mock = MockEmbeddingsServer.new.start
    mock_registry_config(@mock)
    @tool = build_tool("web_search") # placeholder, replaced below
    @tool = build_tool("retrieve")
  end

  def teardown
    super
    @mock&.stop
  end

  def vector(rows) = Array.new(384, 0.5)

  def test_model_name_refused_byte_matched
    assert_refusal("retrieve", "model-name-refused", slots: {}, planted: []) do
      execute_tool(@tool, query: "q", model: "some-model")
    end
  end

  def test_retrieval_runs_keyless_through_the_mock_registry_row
    source = mint_source(snapshot: "the momentum passage about transaction costs\n")
    strategy = PipelineFixtures.mint_strategy(conn)
    chunk_id = conn[:chunks].insert(
      source_id: source[:id], user_id: @user_id, strategy_id: strategy, ordinal: 1,
      text: "the momentum passage about transaction costs", char_start: 0,
      char_end: 44, snapshot_char_count: source[:text].length, source_anchorable: true
    )
    vec = Array.new(384, 0.5)
    @mock.script([{type: :embeddings, vectors: [vec]}])
    job = PipelineFixtures.mint_embed_job(conn, user_id: @user_id, quest_id: @quest_id,
                                          phase_id: @session[:phase_id], kind: "embed",
                                          model_id: PipelineFixtures::MINILM_MODEL_ID,
                                          target_kind: "chunk", idem_key: "embed:test:c1")
    conn[:emb_minilm_ab_384].insert(
      model_id: PipelineFixtures::MINILM_MODEL_ID, model_status: "active", user_id: @user_id,
      target_kind: "chunk", chunk_id: chunk_id,
      embedding: "[#{vec.join(',')}]", embedded_text: "the momentum passage", job_id: job
    )

    @mock.rearm!
    hits = execute_tool(@tool, query: "momentum passage", kinds: ["chunk"])
    assert_includes hits, "[chunk]", "the FTS+dense hit surfaces with its kind"
  end

  def test_query_embedded_exactly_once_per_search
    @mock.script([{type: :embeddings, vectors: [Array.new(384, 0.5)]}])
    execute_tool(@tool, query: "a query", kinds: ["claim"])
    @mock.captured_requests
    @mock.rearm!
    @mock.script([{type: :embeddings, vectors: [Array.new(384, 0.5)]}])
    execute_tool(@tool, query: "another query", kinds: ["claim"])
    assert_equal 1, @mock.captured_requests.size, "ONE embed wire call per search"
  end
end
