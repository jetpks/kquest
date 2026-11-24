# frozen_string_literal: true

require_relative "texts_test"

# frontier_add — pose a claim on the scored queue.
class FrontierAddTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/frontier_add.md", __dir__)

  def setup
    mint
    @claim = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                         text: "a posed claim")
    @tool = build_tool("frontier_add")
  end

  def test_opens_an_entry_with_mass
    answer = execute_tool(@tool, claim: "K1", need: "the underlying study, named (authors, year, venue)",
                          uncertainty: 4, relevance: 5)
    entry = conn[:frontier_entries].where(quest_id: @quest_id).first
    assert entry
    assert_equal "open", entry[:state]
    assert_includes answer, "mass=20"
  end

  def test_frontier_re_add_refusal_byte_matched
    execute_tool(@tool, claim: "K1", need: "a first need", uncertainty: 4, relevance: 5)
    assert_refusal("frontier_add", "frontier-re-add", slots: {alias: "K1"}, planted: ["K1"]) do
      execute_tool(@tool, claim: "K1", need: "a second need", uncertainty: 4, relevance: 5)
    end
  end

  def test_duplicate_need_refusal_byte_matched
    claim2 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 2,
                                         text: "another claim")
    execute_tool(@tool, claim: "K2", need: "the same open need string", uncertainty: 3, relevance: 3)
    _ = claim2
    assert_refusal("frontier_add", "duplicate-need",
                   slots: {located: "\"the same open need string\" on K2"},
                   planted: ["the same open need string", "K2"]) do
      execute_tool(@tool, claim: "K1", need: "the same open need string", uncertainty: 4, relevance: 5)
    end
  end

  def test_score_range_refusal_byte_matched
    assert_refusal("frontier_add", "score-range", slots: {}, planted: []) do
      execute_tool(@tool, claim: "K1", need: "a need", uncertainty: 6, relevance: 5)
    end
  end

  def test_unknown_node_refusal_byte_matched
    assert_refusal("frontier_add", "unknown-node", slots: {id: "K42"}, planted: ["K42"]) do
      execute_tool(@tool, claim: "K42", need: "a need", uncertainty: 4, relevance: 5)
    end
  end
end
