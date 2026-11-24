# frozen_string_literal: true

require_relative "texts_test"

# mass — frontier mass + open count over v_frontier_mass.
class MassTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/mass.md", __dir__)

  def setup
    mint
    @tool = build_tool("mass")
  end

  def test_answer_shape_byte_matched_against_the_frozen_block
    claim = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                        text: "a queued claim")
    conn[:frontier_entries].insert(user_id: @user_id, quest_id: @quest_id, claim_id: claim,
                                   need: "a need", uncertainty: 4, relevance: 5, state: "open",
                                   spawned_by_phase_id: @session[:phase_id])

    expected = frozen_answer("mass").sub("frontier_mass=98", "frontier_mass=20")
                                    .sub("frontier_open=17", "frontier_open=1")
    assert_equal expected, execute_tool(@tool)
  end

  def test_empty_queue_is_zero_zero
    assert_equal "mass: frontier_mass=0 frontier_open=0", execute_tool(@tool)
  end
end
