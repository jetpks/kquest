# frozen_string_literal: true

require_relative "texts_test"

# edge_add — ordered typed edge derives_from claim→claim.
class EdgeAddTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/edge_add.md", __dir__)

  def setup
    mint
    @from = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                        text: "the deriving claim")
    @to = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 2,
                                      text: "the grounding claim")
    @tool = build_tool("edge_add")
  end

  def test_inserts_ordered_edge_at_max_plus_one
    a = execute_tool(@tool, from: "K1", to: "K2")
    assert_includes a, "position 1"

    # second edge position = max+1
    PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 3,
                                text: "a third claim")
    execute_tool(@tool, from: "K1", to: "K3")
    positions = conn[:claim_derivations].where(claim_id: @from).map { |r| r[:position] }
    assert_equal [1, 2], positions.sort
  end

  def test_duplicate_edge_refusal_byte_matched
    execute_tool(@tool, from: "K1", to: "K2")
    assert_refusal("edge_add", "duplicate-edge", slots: {from: "K1", to: "K2"},
                   planted: ["K1 derives_from K2"]) do
      execute_tool(@tool, from: "K1", to: "K2")
    end
  end

  def test_self_derivation_refusal_byte_matched
    assert_refusal("edge_add", "self-derivation", slots: {alias: "K1"}, planted: ["K1 → K1"]) do
      execute_tool(@tool, from: "K1", to: "K1")
    end
  end

  def test_wrong_endpoint_refusal_byte_matched
    assert_refusal("edge_add", "wrong-endpoint", slots: {got: "got evidence"}, planted: []) do
      execute_tool(@tool, from: "K1", to: "E1")
    end
  end

  def test_unknown_node_refusal_byte_matched
    assert_refusal("edge_add", "unknown-node", slots: {id: "K9"}, planted: ["K9"]) do
      execute_tool(@tool, from: "K9", to: "K2")
    end
  end
end
