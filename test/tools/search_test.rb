# frozen_string_literal: true

require_relative "texts_test"

# search — substring match over node TEXT; id-probes refused with the
# resolution recipe.
class SearchTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/search.md", __dir__)

  def setup
    mint
    @tool = build_tool("search")
  end

  def test_substring_match_over_claim_text_capped_with_continuation
    25.times do |i|
      PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: i + 1,
                                  text: "asset allocation claim number #{i}")
    end
    lines = execute_tool(@tool, text: "asset allocation").split("\n")
    assert_equal 21, lines.size, "20 rows + the cap-continuation note"
    assert lines.last.start_with?("(capped at 20 rows")
    assert_equal Kquest::Tools::Texts.cap_note(n: 20, last_id: "K20"), lines.last
  end

  def test_id_probe_refusal_byte_matched
    assert_refusal("search", "id-probe", slots: {}, planted: []) do
      execute_tool(@tool, text: "K50")
    end
    assert_refusal("search", "id-probe", slots: {}, planted: []) do
      execute_tool(@tool, text: "kb:claim:AAAAAAAAA1")
    end
  end

  def test_snippets_capped_at_configured_chars
    long_text = "asset allocation " + "x" * 300
    PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1, text: long_text)
    line = execute_tool(@tool, text: "asset allocation").split("\n").first
    assert line.end_with?("…"), "the snippet is cut with an ellipsis, never silently"
    assert line.length <= 120 + "K1 ".length + 1
  end
end
