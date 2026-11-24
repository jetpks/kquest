# frozen_string_literal: true

require_relative "texts_test"

# neighbors — bounded-radius cycle-safe neighborhood (Q3's shape).
class NeighborsTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/neighbors.md", __dir__)

  def setup
    mint
    @k1 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                      text: "the center claim")
    @k2 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 2,
                                      text: "the parent claim")
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: @k1,
                                    parent_claim_id: @k2, position: 1)
    @tool = build_tool("neighbors")
  end

  def test_bounded_cycle_safe_walk
    # wire K2 back to K1 — a cycle the walk must survive
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: @k2,
                                    parent_claim_id: @k1, position: 1)
    lines = execute_tool(@tool, node: "K1").split("\n")
    assert lines.any? { |l| l.include?("K2") }
    assert lines.any? { |l| l.include?("derivation") || l.include?("claim") }
  end

  def test_type_and_direction_filters
    lines = execute_tool(@tool, node: "K1", types: ["supports"]).split("\n")
    refute lines.any? { |l| l.include?("K2") }, "a supports-only filter sees no derivation parent"
  end

  def test_unknown_node_refusal_byte_matched
    assert_refusal("neighbors", "unknown-node", slots: {id: "K77"}, planted: ["K77"]) do
      execute_tool(@tool, node: "K77")
    end
  end
end
