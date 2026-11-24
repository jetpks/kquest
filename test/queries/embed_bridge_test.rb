# frozen_string_literal: true

require_relative "../tools/texts_test"
require_relative "../support/mock_embeddings_server"

# embed_bridge — the query-text → vector seam (the registry path).
class EmbedBridgeQueryTest < Minitest::Test
  include ToolRig

  def setup
    mint
    @mock = MockEmbeddingsServer.new.start
    mock_registry_config(@mock)
  end

  def teardown
    super
    @mock&.stop
  end

  def test_embeds_through_the_local_registry_row_keyless
    vec = Array.new(384, 0.5)
    @mock.script([{type: :embeddings, vectors: [vec], usage: {prompt_tokens: 7, total_tokens: 7}}])
    bridge = Kquest::Queries::EmbedBridge.new(conn: conn, config: default_config)

    Sync do
      result = bridge.embed(["a query text"])
      assert_equal [vec], result[:vectors]
      assert_equal({prompt_tokens: 7, total_tokens: 7}, result[:usage])
    end

    logged = @mock.captured_request_logs
    assert_equal 1, logged.size
    assert_match(/\/embeddings\z/, logged[0][:path])
  end

  def test_batching_rides_the_registry_row_caps
    vec = Array.new(384, 0.5)
    # batch_max_texts 2 (the test row's cap is data): 3 texts → 2 wire calls
    @mock.script([{type: :embeddings, vectors: [vec, vec]}, {type: :embeddings, vectors: [vec]}])
    PipelineFixtures.register_test_model(conn, @mock, batch_max_texts: 2)
    bridge = Kquest::Queries::EmbedBridge.new(conn: conn, config: default_config)
    Sync do
      result = bridge.embed(["a", "b", "c"])
      assert_equal 3, result[:vectors].size
    end
    assert_equal 2, @mock.captured_requests.size
  end

  def test_the_pristine_bge_row_is_never_touched
    # tests address the registry BY ID — the seeded bge-m3 row stays pristine
    row = conn[:embedding_models].where(id: "92000000-0000-4000-8000-000000000001").first
    assert_equal "bge-m3", row[:wire_name]
    assert_equal "https://openrouter.ai/api/v1/embeddings", row[:endpoint]
    assert_equal "env:OPENROUTER_API_KEY", row[:api_key_ref]
  end
end
