# frozen_string_literal: true

require_relative "texts_test"

# source_read — SLICED snapshot reads; the hard-mode cap refusal.
class SourceReadTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/source_read.md", __dir__)

  def setup
    mint
    lines = (1..100).map { |i| "line #{i} of the fixture snapshot with Brinson content" }
    @source = mint_source(snapshot: lines.join("\n"))
    @tool = build_tool("source_read")
  end

  def test_sliced_read_returns_the_lines
    text = execute_tool(@tool, src: "C1", offset: 2, limit: 3)
    assert_equal "line 2 of the fixture snapshot with Brinson content\n" \
                 "line 3 of the fixture snapshot with Brinson content\n" \
                 "line 4 of the fixture snapshot with Brinson content", text
  end

  def test_default_limit_is_60_lines
    text = execute_tool(@tool, src: "C1")
    assert_equal 60, text.lines.size
  end

  def test_non_sliced_read_refusal_byte_matched_hard_mode
    conn[:engine_config].insert(key: "engine.read_slice_cap_chars", value: 8000, mode: "hard",
                                provenance: "test-minted hard line (I05 DR-04 ruling A)")
    mint_source(snapshot: "x" * 9000, added_at: Time.now + 60) # deterministically C2
    cfg = Kquest::Engine.config(conn)
    tool = build_tool("source_read", config: cfg)
    big_urn = Kquest::Queries.resolve_source(conn, user_id: @user_id, quest_id: @quest_id,
                                             ref: "C2")[:urn]
    assert_refusal("source_read", "non-sliced-read",
                   slots: {src: big_urn, cap_seg: "cap 8000 chars/slice"},
                   planted: [big_urn]) do
      execute_tool(tool, src: "C2")
    end
  end

  def test_advisory_mode_executes_with_the_cap_continuation_note
    mint_source(snapshot: "x" * 9000) # C2
    conn[:engine_config].where(key: "engine.read_slice_cap_chars").update(mode: "advisory")
    cfg = Kquest::Engine.config(conn)
    tool = build_tool("source_read", config: cfg)
    text = execute_tool(tool, src: "C2")
    assert_includes text, Kquest::Tools::Texts.cap_note(n: 8000, last_id: "L60")
  end

  def test_unknown_source_refusal_byte_matched
    assert_refusal("source_read", "unknown-source", slots: {src: "C99"}, planted: ["C99"]) do
      execute_tool(@tool, src: "C99")
    end
  end

  def test_offset_beyond_eof_refusal_byte_matched
    assert_refusal("source_read", "offset-beyond-eof",
                   slots: {offset: "offset 5000", lines: "100 lines", range: "1..100"},
                   planted: ["100 lines"]) do
      execute_tool(@tool, src: "C1", offset: 5000)
    end
  end
end
