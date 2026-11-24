# frozen_string_literal: true

require_relative "texts_test"

# frontier_close — close an OPEN entry; refuses closure regressions.
class FrontierCloseTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/frontier_close.md", __dir__)

  def setup
    mint
    @claim = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                         text: "a queued claim")
    @tool = build_tool("frontier_close")
  end

  def test_closes_the_open_entry
    conn[:frontier_entries].insert(user_id: @user_id, quest_id: @quest_id, claim_id: @claim,
                                   need: "a need", uncertainty: 4, relevance: 5, state: "open",
                                   spawned_by_phase_id: @session[:phase_id])
    # the claim carries a terminal — the close leaves it satisfying something
    conn[:claims].where(id: @claim).update(terminal_type: "primary-empirical",
                                           terminal_basis: "b")
    answer = execute_tool(@tool, claim: "K1")
    assert_equal "closed", conn[:frontier_entries].where(claim_id: @claim).first[:state]
    assert_includes answer, "closed"
  end

  def test_no_open_entry_refusal_byte_matched
    assert_refusal("frontier_close", "no-open-entry", slots: {alias: "K1"}, planted: ["K1"]) do
      execute_tool(@tool, claim: "K1")
    end
  end

  def test_closure_violation_refusal_byte_matched
    conn[:frontier_entries].insert(user_id: @user_id, quest_id: @quest_id, claim_id: @claim,
                                   need: "a need", uncertainty: 4, relevance: 5, state: "open",
                                   spawned_by_phase_id: @session[:phase_id])
    # terminal-less, derivation-less claim: closing leaves it satisfying nothing
    assert_refusal("frontier_close", "closure-violation", slots: {alias: "K1"}, planted: ["K1"]) do
      execute_tool(@tool, claim: "K1")
    end
  end
end
