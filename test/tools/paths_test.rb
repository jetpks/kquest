# frozen_string_literal: true

require_relative "texts_test"

# paths — derivation descent to typed terminals (Q1's shape); the depth belt.
class PathsTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/paths.md", __dir__)

  def setup
    mint
    @k1 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                      text: "the deriving claim")
    @k2 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 2,
                                      text: "the middle claim")
    @k3 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 3,
                                      text: "the terminal claim")
    conn[:claims].where(id: @k3).update(terminal_type: "primary-empirical", terminal_basis: "b")
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: @k1,
                                    parent_claim_id: @k2, position: 1)
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: @k2,
                                    parent_claim_id: @k3, position: 1)
    @tool = build_tool("paths")
  end

  def test_descent_reaches_the_typed_terminal
    lines = execute_tool(@tool, node: "K1").split("\n")
    assert_equal 1, lines.size
    assert_match(/depth 2 → K3 \[primary-empirical\]/, lines.first)
  end

  def test_dangling_leaf_violation_half
    # K4 derives from K5; K5 has no terminal, no parents, no open frontier —
    # the walk dangles mid-air there (Q1V's violation half)
    k4 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 4,
                                     text: "a dangling origin")
    k5 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 5,
                                     text: "a dangling leaf")
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: k4,
                                    parent_claim_id: k5, position: 1)
    rows = Kquest::Queries::DerivationPaths.new(conn: conn)
                                          .dangling_leaves(user_id: @user_id, quest_id: @quest_id)
    assert rows.any? { |r| r[:dangling_claim_id] == k5 }
  end

  def test_depth_cap_refusal_byte_matched
    cfg = default_config.merge("tools.cap_paths_depth" => 1)
    tool = build_tool("paths", config: cfg)
    assert_refusal("paths", "depth-cap", slots: {depth: "depth 1"}, planted: ["depth 1"]) do
      execute_tool(tool, node: "K1")
    end
  end

  def test_unknown_node_refusal_byte_matched
    assert_refusal("paths", "unknown-node", slots: {id: "K99"}, planted: ["K99"]) do
      execute_tool(@tool, node: "K99")
    end
  end
end
