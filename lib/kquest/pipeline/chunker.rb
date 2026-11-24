# frozen_string_literal: true

module Kquest
  module Pipeline
    # L1 verbatim chunker: every chunk is `text[char_start...char_end]`
    # byte-exact (char offsets are CHARACTER offsets — chunks'
    # ck_chunks_len_coherent compares SQL char_length). Parameters are the
    # chunk_strategies ROW's data, never code.
    #
    # paragraph_aligned: accumulate whole paragraphs toward target_chars; a
    # paragraph longer than the target stands alone (over-target chunks are
    # legal — the embed admission control is the loud backstop); overlap
    # re-carries trailing paragraphs (paragraph granularity).
    #
    # not paragraph_aligned: slide character windows of target_chars with
    # overlap_chars between them.
    module Chunker
      Chunk = Struct.new(:char_start, :char_end, :text, keyword_init: true)

      module_function

      def call(text, target_chars:, overlap_chars:, paragraph_aligned:)
        raise Error, "target_chars must be positive (got #{target_chars.inspect})" unless target_chars.to_i > 0

        if paragraph_aligned
          paragraph_chunks(text, target_chars.to_i, overlap_chars.to_i)
        else
          window_chunks(text, target_chars.to_i, overlap_chars.to_i)
        end
      end

      # Paragraph spans as [start, end) character offsets; the separator
      # newline rides the END of its paragraph so concatenation is verbatim.
      def paragraph_spans(text)
        spans = []
        pos = 0
        text.each_line("\n") do |line|
          spans << [pos, pos + line.length]
          pos += line.length
        end
        spans
      end

      def paragraph_chunks(text, target_chars, overlap_chars)
        spans = paragraph_spans(text)
        return [] if spans.empty?

        chunks = []
        # start_idx: the index the next chunk STARTS at (carried tail); i:
        # the next paragraph not yet covered by any chunk.
        i = 0
        start_idx = 0
        while i < spans.size
          j = i
          size = spans[start_idx...i].sum { |s, e| e - s }
          has_carry = start_idx < i
          loop do
            para_size = spans[j][1] - spans[j][0]
            # A paragraph longer than the target stands alone — but only
            # when nothing is carried (after a carry, at least one NEW
            # paragraph joins the chunk: no duplicate standalone emission).
            break unless size.zero? || size + para_size <= target_chars || (j == i && has_carry)

            size += para_size
            j += 1
            break if j >= spans.size
          end
          chunks << span_chunk(text, spans, start_idx, j - 1)

          # Overlap: re-carry trailing paragraphs of the emitted chunk while
          # they fit in overlap_chars. carry_start tracks the FIRST carried
          # paragraph; the default is no carry (overlap 0, or the last
          # paragraph alone exceeds the overlap budget) — the next chunk
          # then starts at the first uncovered paragraph.
          carry_start = j
          last = j - 1
          last_size = spans[last][1] - spans[last][0]
          if overlap_chars > 0 && last_size <= overlap_chars
            carry_start = last
            carry_size = last_size
            while carry_start > start_idx
              k = carry_start - 1
              break unless carry_size + (spans[k][1] - spans[k][0]) <= overlap_chars

              carry_size += spans[k][1] - spans[k][0]
              carry_start = k
            end
          end
          i = j
          start_idx = carry_start
        end
        chunks
      end

      def span_chunk(text, spans, first, last)
        char_start = spans[first][0]
        char_end = spans[last][1]
        Chunk.new(char_start: char_start, char_end: char_end, text: text[char_start...char_end])
      end

      def window_chunks(text, target_chars, overlap_chars)
        step = target_chars - overlap_chars
        raise Error, "overlap_chars (#{overlap_chars}) must be < target_chars (#{target_chars})" if step <= 0

        chunks = []
        start = 0
        while start < text.length
          char_end = [start + target_chars, text.length].min
          chunks << Chunk.new(char_start: start, char_end: char_end, text: text[start...char_end])
          # A window reaching the end of the text ends the slide — a later
          # start would only re-emit a suffix the last window already covers.
          break if char_end >= text.length

          start += step
        end
        chunks
      end
    end
  end
end
