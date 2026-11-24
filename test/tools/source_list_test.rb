# frozen_string_literal: true

require_relative "texts_test"

# source_list — the staged-corpus listing (the frozen answer shape; C-id =
# the staging ordinal).
class SourceListTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/source_list.md", __dir__)

  def setup
    mint
    @tool = build_tool("source_list")
  end

  def test_answer_lines_follow_the_frozen_shape_with_staging_ordinals
    s1 = mint_source(snapshot: "x" * 100, title: "First staged", added_at: Time.now - 60)
    s2 = mint_source(snapshot: "y" * 55, role: "agenda", title: "Second staged", added_at: Time.now - 30)

    lines = execute_tool(@tool).split("\n")
    assert_equal 2, lines.size
    expected = frozen_answer("source_list").split("\n").first
      .sub(/\AC\d+/, "C1").sub(/kb:src:\w+/, s1[:urn])
      .sub('"Determinants of Portfolio Performance"', '"First staged"')
      .sub("41830 chars", "100 chars").sub("chunks=42", "chunks=0")
      .sub("embedded", "not-embedded")
    assert_equal expected, lines.first
    assert lines[1].start_with?("C2 [")
    assert_includes lines[1], "agenda"
  end

  def test_c_id_order_is_staging_order
    mint_source(snapshot: "a", added_at: Time.now - 10)
    mint_source(snapshot: "b", added_at: Time.now - 5)
    lines = execute_tool(@tool).split("\n")
    assert lines.first.start_with?("C1 [")
    assert lines.last.start_with?("C2 [")
  end

  def test_cap_continuation_note
    55.times { |i| mint_source(snapshot: "s#{i}", added_at: Time.now - (200 - i)) }
    lines = execute_tool(@tool).split("\n")
    assert_equal 51, lines.size
    assert_equal Kquest::Tools::Texts.cap_note(n: 50, last_id: "C50"), lines.last
  end
end
