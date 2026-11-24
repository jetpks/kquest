# frozen_string_literal: true

require_relative "texts_test"

# list — the capped node listing (the frozen answer shape).
class ListTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/list.md", __dir__)

  def setup
    mint
    @tool = build_tool("list")
  end

  def test_answer_lines_follow_the_frozen_shape
    c1 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                     text: "Long-term investment policy explained an average 93.6 percent")
    urn = conn[:claims].where(id: c1).first[:urn]
    line = execute_tool(@tool, label: "claim").split("\n").first

    frozen = frozen_answer("list").split("\n").first
    # the frozen line's slots: the K-alias, the urn, the snippet + ellipsis
    expected = frozen
      .sub(/\AK\d+/, "K1")
      .sub(/\[urn:claim:[^\]]+\]/, "[#{urn}]")
      .sub(/claim .*/, "claim Long-term investment policy explained an average 93.6 percent")
    _ = c1
    assert_equal expected, line
  end

  def test_cap_continuation_note
    55.times do |i|
      PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: i + 1,
                                  text: "claim text #{i}")
    end
    lines = execute_tool(@tool, label: "claim").split("\n")
    assert_equal 51, lines.size
    assert_equal Kquest::Tools::Texts.cap_note(n: 50, last_id: "K50"), lines.last
  end

  def test_unknown_label_refusal_byte_matched
    assert_refusal("list", "unknown-label", slots: {named: "UNKNOWN-LABEL: frontier"},
                   planted: ["frontier"]) do
      execute_tool(@tool, label: "frontier")
    end
  end

  def test_after_continuation_resumes_past_the_named_row
    55.times do |i|
      PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: i + 1,
                                  text: "claim text #{i}")
    end
    lines = execute_tool(@tool, label: "claim", after: "K50").split("\n")
    assert lines.first.start_with?("K51")
  end
end
