# frozen_string_literal: true

require_relative "../tools/texts_test"
require_relative "../support/mock_embeddings_server"

# dedup_candidates — I03 family (d), transcribed (exact + near + hub seam).
class DedupCandidatesQueryTest < Minitest::Test
  include ToolRig

  EXISTING = "Net-of-cost momentum persists modestly once the cost assumptions are applied."
  PROBE = "Net-of-cost momentum persists modestly once the cost assumptions are used here."

  def setup
    mint
    @mock = MockEmbeddingsServer.new.start
    mock_registry_config(@mock)
    @query = Kquest::Queries::DedupCandidates.new(conn: conn)
  end

  def teardown
    super
    @mock&.stop
  end

  def staged_claim_with_vector(text, seq)
    claim = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: seq, text: text)
    vec = Array.new(384) { |i| (i % 97) / 97.0 }
    job = PipelineFixtures.mint_embed_job(conn, user_id: @user_id, quest_id: @quest_id,
                                          phase_id: @session[:phase_id], kind: "embed",
                                          model_id: PipelineFixtures::MINILM_MODEL_ID,
                                          target_kind: "claim", idem_key: "embed:test:#{seq}")
    conn[:emb_minilm_ab_384].insert(
      model_id: PipelineFixtures::MINILM_MODEL_ID, model_status: "active", user_id: @user_id,
      target_kind: "claim", claim_id: claim, embedding: "[#{vec.join(',')}]",
      embedded_text: "fixture", job_id: job
    )
    claim
  end

  # the frozen family property (AC4): the exact leg is BYTE-equality — a
  # near-duplicate wording is INVISIBLE to it
  def test_dedup_exact_leg_cannot_see_near_duplicates
    staged_claim_with_vector(EXISTING, 1)
    result = @query.candidates(user_id: @user_id, text: PROBE)
    assert_empty result[:exact], "the exact leg cannot see the near-duplicate"
    assert_empty result[:near], "no probe vector: the near leg stays empty"
  end

  def test_exact_leg_refuses_the_byte_equal_text
    staged_claim_with_vector(EXISTING, 1)
    result = @query.candidates(user_id: @user_id, text: EXISTING)
    assert_equal 1, result[:exact].size
    assert_equal "exact", result[:exact].first.match_kind
  end

  def test_near_leg_ordering_and_floor_under_config_keys
    staged_claim_with_vector(EXISTING, 1)
    # k + floor are READ FROM tool_config (never hardcoded)
    conn[:tool_config].where(key: "tools.dedup_near_top_k").delete
    conn[:tool_config].insert(key: "tools.dedup_near_top_k", num_value: 5,
                              provenance: "test-minted config data")
    conn[:tool_config].where(key: "tools.dedup_near_floor").delete
    conn[:tool_config].insert(key: "tools.dedup_near_floor", num_value: 0.8387,
                              provenance: "test-minted config data")

    vec = Array.new(384) { |i| (i % 97) / 97.0 } # identical to the staged vector
    result = @query.candidates(user_id: @user_id, text: PROBE, probe_vector: vec)
    assert_equal 1, result[:near].size
    assert_equal "near_dup", result[:near].first.match_kind
    assert_equal 1.0, result[:near].first.cosine
    assert result[:near].first.hub_entry, "the candidate maps onto its v_canonical_claims entry"
  end

  def test_user_scoping_is_a_parameter
    staged_claim_with_vector(EXISTING, 1)
    other = PipelineFixtures.mint_tenancy(conn)
    vec = Array.new(384) { |i| (i % 97) / 97.0 }
    result = @query.candidates(user_id: other[:user_id], text: PROBE, probe_vector: vec)
    assert_empty result[:exact]
    assert_empty result[:near], "another tenant's vectors are invisible (the hub is per-user)"
    PipelineFixtures.cleanup(conn, user_id: other[:user_id])
  end
end
