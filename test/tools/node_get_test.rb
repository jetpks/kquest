# frozen_string_literal: true

require_relative "texts_test"
require "json"

# node_get — one node by K-alias or urn, with in/out edges.
class NodeGetTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/node_get.md", __dir__)

  def setup
    mint
    @claim = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                         text: "the fetched claim")
    @tool = build_tool("node_get")
  end

  def test_fetch_by_alias_returns_edges_and_fields
    parent = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 2,
                                         text: "the parent claim")
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: @claim,
                                    parent_claim_id: parent, position: 1)

    result = JSON.parse(execute_tool(@tool, node: "K1"))
    assert_equal "K1", result["alias"]
    assert_equal conn[:claims].where(id: @claim).first[:urn], result["urn"]
    assert_equal "the fetched claim", result["text"]
    assert_equal "K2", result["derives_from"][0]["alias"]
  end

  def test_fetch_by_urn
    result = JSON.parse(execute_tool(@tool, node: conn[:claims].where(id: @claim).first[:urn]))
    assert_equal "K1", result["alias"]
  end

  def test_unknown_node_refusal_byte_matched
    assert_refusal("node_get", "unknown-node", slots: {id: "K7"}, planted: ["K7"]) do
      execute_tool(@tool, node: "K7")
    end
  end
end
