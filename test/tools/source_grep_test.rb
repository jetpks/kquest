# frozen_string_literal: true

require_relative "texts_test"

# source_grep — pattern → line numbers + context lines.
class SourceGrepTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/source_grep.md", __dir__)

  def setup
    mint
    lines = (1..20).map { |i| "line #{i}: filler" }
    lines[9] = "line 10: the Brinson passage lives here"
    lines[11] = "line 12: another Brinson mention"
    @source = mint_source(snapshot: lines.join("\n"))
    @tool = build_tool("source_grep")
  end

  def test_grep_returns_line_numbers_and_context_lines
    text = execute_tool(@tool, src: "C1", pattern: "Brinson", context: 1)
    assert_includes text, "10: line 10: the Brinson passage lives here"
    assert_includes text, "12: line 12: another Brinson mention"
  end

  def test_ignore_case
    lines = (1..5).map { |i| "line #{i}" }
    lines[2] = "line 3: BRINSON upper"
    mint_source(snapshot: lines.join("\n")) # C2
    text = execute_tool(@tool, src: "C2", pattern: "brinson", ignore_case: true)
    assert_includes text, "3: line 3: BRINSON upper"
  end

  def test_unknown_source_refusal_byte_matched
    assert_refusal("source_grep", "unknown-source", slots: {src: "C99"}, planted: ["C99"]) do
      execute_tool(@tool, src: "C99", pattern: "x")
    end
  end

  def test_pattern_required_refusal_byte_matched
    assert_refusal("source_grep", "pattern-required", slots: {}, planted: []) do
      execute_tool(@tool, src: "C1", pattern: "")
    end
  end
end
