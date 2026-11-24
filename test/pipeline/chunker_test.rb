# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/pipeline_fixtures"

# L1 verbatim chunking, one named property per frozen law. Parameters are
# the chunk_strategies ROW's data, never code.
class ChunkerTest < Minitest::Test
  def chunk(text, **params)
    Kquest::Pipeline::Chunker.call(text, **params)
  end

  def test_verbatim_substrings_with_exact_offsets
    text = "Alpha beta.\nGamma delta.\n"
    chunks = chunk(text, target_chars: 12, overlap_chars: 0, paragraph_aligned: true)
    chunks.each do |c|
      assert_equal c.text, text[c.char_start...c.char_end], "L1: every chunk is text[char_start...char_end]"
      assert_equal c.text.length, c.char_end - c.char_start
    end
  end

  def test_accumulation_and_over_target_paragraph_stands_alone
    text = "one\n" \
           "two\n" \
           "X#{'y' * 40}Z\n" \
           "three\n"
    chunks = chunk(text, target_chars: 8, overlap_chars: 0, paragraph_aligned: true)
    texts = chunks.map(&:text)
    # Accumulation toward the target: "one\ntwo\n" fits in 8.
    assert_includes texts, "one\ntwo\n"
    # A paragraph longer than the target stands ALONE (over-target legal).
    over = chunks.find { |c| c.text.include?("X#{'y' * 40}Z") }
    refute_nil over
    assert_equal "X#{'y' * 40}Z\n", over.text
    assert_operator over.text.length, :>, 8
  end

  def test_paragraph_overlap_carries_trailing_paragraphs
    text = "aaaa\nbbbb\ncccc\ndddd\n"
    chunks = chunk(text, target_chars: 10, overlap_chars: 5, paragraph_aligned: true)
    texts = chunks.map(&:text)
    # First chunk accumulates "aaaa\nbbbb\n" (10 ≤ 10); "cccc\n" would
    # exceed → emit, and the trailing "bbbb\n" (5 ≤ overlap 5) carries.
    assert_equal "aaaa\nbbbb\n", texts[0]
    assert_equal "bbbb\ncccc\n", texts[1]
    assert_equal "cccc\ndddd\n", texts[2]
    # Overlap is verbatim: the carried bytes equal the previous chunk's tail.
    assert_equal texts[0][-5..], texts[1][0, 5]
    assert_equal texts[1][-5..], texts[2][0, 5]
  end

  def test_non_aligned_window_slide
    text = "abcdefghij" * 2 # 20 chars
    chunks = chunk(text, target_chars: 8, overlap_chars: 2, paragraph_aligned: false)
    # Windows of 8 sliding by (8-2)=6: [0,8) [6,14) [12,20)
    assert_equal [[0, 8], [6, 14], [12, 20]],
      chunks.map { |c| [c.char_start, c.char_end] }
    assert_equal "abcdefgh", chunks[0].text
    assert_equal "ghijabcd", chunks[1].text
    assert_equal "cdefghij", chunks[2].text
    # Every window verbatim; the slide is lossless (coverage reaches the end).
    chunks.each { |c| assert_equal text[c.char_start...c.char_end], c.text }
    assert_equal text.length, chunks.last.char_end
  end
end
