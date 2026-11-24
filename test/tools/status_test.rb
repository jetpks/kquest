# frozen_string_literal: true

require_relative "texts_test"

# status — the gate dashboard (EXACTLY the parity fields; the frozen answer
# shape with this quest's values).
class StatusTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/status.md", __dir__)

  def setup
    mint
    @tool = build_tool("status")
  end

  def test_answer_shape_byte_matched_against_the_frozen_block
    minted = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                         text: "a claim")
    conn[:claims].where(id: minted).update(terminal_type: "primary-empirical", terminal_basis: "b")
    source = mint_source(snapshot: "some snapshot text\n")
    conn[:evidence].insert(user_id: @user_id, quest_id: @quest_id, source_id: source[:id],
                           source_anchorable: true, snapshot_char_count: source[:text].length,
                           span_start: 0, span_end: 13, span_text: "some snapshot",
                           reading: "a reading")
    evidence_id = conn[:evidence].where(quest_id: @quest_id).first[:id]
    conn[:evidence_edges].insert(user_id: @user_id, quest_id: @quest_id, evidence_id: evidence_id,
                                 relation: "supports", claim_id: minted, position: 1)

    produced = execute_tool(@tool)
    frozen = frozen_answer("status")
    # the frozen block's numbers are the field SLOTS — substitute this quest's
    expected = frozen
      .sub("claims=531", "claims=1").sub("evidence=1016", "evidence=1")
      .sub("decompose_remaining=2", "decompose_remaining=0")
      .sub("frontier_open=17", "frontier_open=0").sub("frontier_mass=98", "frontier_mass=0")
      .sub("bare_claims=0", "bare_claims=0").sub("unreferenced=0", "unreferenced=0")
      .sub("dual_arm_claims=0", "dual_arm_claims=0")
    assert_equal expected, produced
  end

  def test_parity_fields_are_exactly_the_frozen_set
    # no decorative fields: the produced line's field tokens = the frozen
    # block's field tokens, 1:1 both directions
    produced = execute_tool(@tool)
    frozen_fields = frozen_answer("status").scan(/(\w+)=[^\s]+/).map(&:first).sort
    produced_fields = produced.scan(/(\w+)=[^\s]+/).map(&:first).sort
    assert_equal frozen_fields, produced_fields
  end
end
