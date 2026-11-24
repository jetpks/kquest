# frozen_string_literal: true

require_relative "../tools/texts_test"
require "kernel/sync"
require_relative "../support/mock_embeddings_server"

# retrieve_hybrid — I03 families (a)/(b)/(c), transcribed.
class RetrieveHybridQueryTest < Minitest::Test
  include ToolRig

  QUERY = "momentum costs passage"

  def setup
    mint
    @mock = MockEmbeddingsServer.new.start
    mock_registry_config(@mock)
    @bridge = Kquest::Queries::EmbedBridge.new(conn: conn, config: default_config)
    @query = Kquest::Queries::RetrieveHybrid.new(conn: conn, bridge: @bridge)

    # a quest corpus with two chunks: one matching BOTH legs, one FTS-only
    @source = mint_source(snapshot: "the momentum costs passage is here\n\nunrelated filler\n")
    @strategy = PipelineFixtures.mint_strategy(conn)
    @c1 = mint_chunk("the momentum costs passage is here")
    @c2 = mint_chunk("momentum costs with no dense affinity")
    stage_vectors("c1" => @c1, "c2" => @c2)
  end

  def teardown
    super
    @mock&.stop
  end

  def mint_chunk(text)
    conn[:chunks].insert(
      source_id: @source[:id], user_id: @user_id, strategy_id: @strategy, ordinal: conn[:chunks].where(source_id: @source[:id]).count + 1,
      text: text, char_start: 0, char_end: text.length,
      snapshot_char_count: @source[:text].length, source_anchorable: true
    )
  end

  def stage_vectors(map)
    vec = Array.new(384, 0.25)
    @mock.script([{type: :embeddings, vectors: [vec]}])
    map.each do |key, chunk_id|
      job = PipelineFixtures.mint_embed_job(conn, user_id: @user_id, quest_id: @quest_id,
                                            phase_id: @session[:phase_id], kind: "embed",
                                            model_id: PipelineFixtures::MINILM_MODEL_ID,
                                            target_kind: "chunk", idem_key: "embed:test:#{key}")
      conn[:emb_minilm_ab_384].insert(
        model_id: PipelineFixtures::MINILM_MODEL_ID, model_status: "active", user_id: @user_id,
        target_kind: "chunk", chunk_id: chunk_id, embedding: "[#{vec.join(',')}]",
        embedded_text: "fixture", job_id: job
      )
    end
  end

  # the frozen family property (AC4): the fused set is the UNION of the legs
  def test_rrf_union_of_legs
    # the query text matches the FTS leg on both chunks; the dense leg (mock
    # vectors identical) ranks both too; an FTS-only chunk must still surface
    hits = Sync do
      @query.search(user_id: @user_id, quest_id: @quest_id, query: QUERY,
                    kinds: ["chunk"], limit: 10)
    end
    ids = hits.map(&:id)
    assert_includes ids, @c1
    assert_includes ids, @c2
  end

  # the frozen family property (AC4): a both-legs hit outranks any single-leg hit
  def test_rrf_both_legs_outrank_single_leg
    hits = Sync do
      @query.search(user_id: @user_id, quest_id: @quest_id, query: QUERY,
                    kinds: ["chunk"], limit: 10)
    end
    both = hits.select { |h| h.dense_rank && h.fts_rank }
    single = hits.select { |h| !(h.dense_rank && h.fts_rank) }
    return flunk "the fixture must exercise both classes" if both.empty? || single.empty?

    assert both.map(&:rrf).min > single.map(&:rrf).max,
           "a both-legs hit outranks any single-leg hit"
  end

  # the frozen family property (AC4): every rrf value equals the formula
  # recomputed (K = 60, weights 1.0, an absent leg contributes 0)
  def test_rrf_formula_recomputed
    hits = Sync do
      @query.search(user_id: @user_id, quest_id: @quest_id, query: QUERY,
                    kinds: ["chunk"], limit: 10)
    end
    hits.each do |h|
      expected = (h.dense_rank ? 1.0 / (60 + h.dense_rank) : 0.0) +
                 (h.fts_rank ? 1.0 / (60 + h.fts_rank) : 0.0)
      assert_in_delta expected, h.rrf, 1e-12
    end
  end

  def test_user_scoping_is_a_parameter
    other = PipelineFixtures.mint_tenancy(conn)
    hits = Sync do
      @query.search(user_id: other[:user_id], quest_id: other[:quest_id], query: QUERY,
                    kinds: ["chunk"], limit: 10)
    end
    assert_empty hits
    PipelineFixtures.cleanup(conn, user_id: other[:user_id])
  end
end
