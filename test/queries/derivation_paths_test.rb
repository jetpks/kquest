# frozen_string_literal: true

require_relative "../tools/texts_test"

# derivation_paths — I01 Q1 (+ Q1V), transcribed.
class DerivationPathsQueryTest < Minitest::Test
  include ToolRig

  def setup
    mint
    @k1 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1, text: "origin claim")
    @k2 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 2, text: "middle claim")
    @k3 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 3, text: "terminal claim")
    conn[:claims].where(id: @k3).update(terminal_type: "definitional-mathematical", terminal_basis: "b")
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: @k1,
                                    parent_claim_id: @k2, position: 1)
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: @k2,
                                    parent_claim_id: @k3, position: 1)
    @query = Kquest::Queries::DerivationPaths.new(conn: conn)
  end

  # the frozen family property (AC4)
  def test_derivation_descent_reaches_typed_terminals
    result = @query.paths(@k1, user_id: @user_id, quest_id: @quest_id, depth_cap: 128)
    terminals = result[:terminals]
    assert_equal 1, terminals.size
    assert_equal @k3, terminals.first[:node_id]
    assert_equal 2, terminals.first[:depth]
    assert_equal "definitional-mathematical", terminals.first[:terminal_type]
    refute result[:truncated]
  end

  def test_depth_cap_bounds_the_walk
    result = @query.paths(@k1, user_id: @user_id, quest_id: @quest_id, depth_cap: 1)
    assert result[:truncated]
    assert_equal 1, result[:max_depth]
  end

  def test_user_scoping_is_a_parameter
    other = PipelineFixtures.mint_tenancy(conn)
    result = @query.paths(@k1, user_id: other[:user_id], quest_id: other[:quest_id], depth_cap: 128)
    assert_empty result[:terminals]
    PipelineFixtures.cleanup(conn, user_id: other[:user_id])
  end
end
