# frozen_string_literal: true

module Kquest
  module Tools
    # The ONE source of every frozen refusal text and canonical call (I14
    # Part 2): the frozen fixture files under
    # design/I05-tool-surface/artifacts/fixtures/ are PARSED AT RUNTIME — no
    # refusal text, canonical call, or canonical answer shape is copied into
    # any tool, query object, or test (copies drift; the fixtures are the
    # byte source of record). `check-fixtures.sh` parses the same strict
    # format; this loader parses it in Ruby.
    #
    #   Texts.tool_names                  → the 24 frozen fixture names (order = I05's tools block)
    #   Texts.canonical_calls(tool)       → every `### canonical` fenced JSON block (T-CALL)
    #   Texts.answer_block(tool)          → the canonical section's ```text block (the frozen answer shape)
    #   Texts.refusal(tool, class, **slots) → the frozen REFUSAL: line, slot-substituted
    #   Texts.error_class(tool, class)    → the census-able rule-id token (DR-01)
    #
    # The substitution law (frozen text, located values — T-LOCATE/DR-01): a
    # token in the frozen line is a SLOT iff it names THE CALL'S OWN located
    # data. The per-class REGISTRY below is data: for each class, an ordered
    # list of [pattern, slot_key, global?] — the pattern anchors enough
    # surrounding frozen context to hit ONLY the slot (the fixtures' teaching
    # fragments — e.g. the `{"label":"claim","text":"…"}` canonical shapes —
    # are frozen text and are never substituted); a required slot missing at
    # call time raises loudly (a wiring defect, never a silent fallback).
    #
    # `harness.md`'s three texts keep their landed I13 producers (the
    # ToolHarness constants); the loader reads that file too so the census
    # (24 tools / 50 refusal sections) parses 1:1 with check-fixtures.sh.
    module Texts
      FIXTURES_DIR = File.expand_path("../../../design/I05-tool-surface/artifacts/fixtures", __dir__)

      module_function

      # The ordered 24-name inventory (I05 §2's `tools` block verbatim — the
      # census order for descriptions and profiles).
      TOOL_NAMES = %w[
        node_add node_set node_get edge_add frontier_add frontier_close
        status search list paths mass neighbors
        source_read source_grep source_list
        web_search web_fetch
        retrieve
        report_draft report_bind
        harness quest_status subagent_spawn subagent_status
      ].freeze

      # ── the fixture parse (one pass per file, memoized) ─────────────────

      def fixture_path(tool)
        File.join(FIXTURES_DIR, "#{tool}.md")
      end

      def parsed(tool)
        @parsed ||= {}
        @parsed[tool] ||= parse_fixture(tool)
      end

      def parse_fixture(tool)
        text = File.read(fixture_path(tool))
        canonicals = []
        answer = nil
        refusals = {}

        canonical = text.split(/^### canonical\n/).fetch(1, nil)
        if canonical
          canonical = canonical.split(/^### /).first
          canonical.scan(/^```(\w*)\n(.*?)^```$/m) do |lang, body|
            if lang == "text"
              answer = body.strip
            else
              canonicals << body.strip
            end
          end
        end

        text.scan(/^### refusal: ([^\n]+)\n(.*?)(?=^### |^## |\z)/m) do |class_id, section|
          # the FULL frozen line (the REFUSAL: prefix is the fixture's byte)
          line = section[/^REFUSAL: .*/]
          raise "fixture #{tool}.md class #{class_id}: no REFUSAL: line" unless line

          refusals[class_id.strip] = line
        end

        {canonicals: canonicals, answer: answer, refusals: refusals}
      end

      def tool_names = TOOL_NAMES

      def canonical_calls(tool) = parsed(tool).fetch(:canonicals)

      def answer_block(tool) = parsed(tool).fetch(:answer)

      def refusal_classes(tool) = parsed(tool).fetch(:refusals).keys

      # The tool's registered description (T-CALL): opens with EVERY canonical
      # call the fixture carries (node_add's claim + evidence forms each open
      # the description).
      def canonical_description(tool)
        parsed(tool).fetch(:canonicals).join("\n")
      end

      # The census-able rule-id token (DR-01): the first UPPER-CASE run of the
      # frozen line after the REFUSAL: prefix (e.g. "DUPLICATE-LABEL"). This
      # is the `tool_calls.error_class` value (the ENTRY 7 census surface).
      def error_class(tool, class_id)
        line = frozen_refusal(tool, class_id)
        line[/\AREFUSAL: ([A-Z][A-Z0-9-]*)/, 1]
      end

      # The frozen REFUSAL: line with its slots substituted. Raises loudly on
      # an unknown tool/class (a wiring defect) and on a missing slot (T-LOCATE:
      # the locate is concrete, never elided).
      def refusal(tool, class_id, **slots)
        line = frozen_refusal(tool, class_id)
        registry(tool, class_id).each do |pattern, key, global|
          value = slots.key?(key) ? slots.fetch(key).to_s : raise_slot_missing(tool, class_id, key)
          line = global ? line.gsub(pattern, value) : line.sub(pattern, value)
        end
        line
      end

      def frozen_refusal(tool, class_id)
        parsed(tool).fetch(:refusals).fetch(class_id) do
          raise KeyError, "no frozen refusal class #{class_id.inspect} in fixtures/#{tool}.md"
        end
      end

      def raise_slot_missing(tool, class_id, key)
        raise KeyError, "refusal #{tool}:#{class_id} requires slot #{key.inspect} — none supplied " \
                        "(T-LOCATE: a refusal's locate is concrete, never elided)"
      end

      # ── the per-class substitution registry (DATA — frozen substring
      #    patterns → slot keys; see the substitution law above) ───────────
      def registry(tool, class_id)
        SUBSTITUTIONS.fetch([tool, class_id], [])
      end

      ID_SLOT = [[/<id>/, :id, true]].freeze # the fixtures' own placeholder form
      BUDGET_LINE = [[/web_calls=\d+\/\d+, mode=\w+/, :line, false]].freeze

      SUBSTITUTIONS = {
        # edge_add
        ["edge_add", "unknown-node"]       => ID_SLOT,
        ["edge_add", "duplicate-edge"]     => [[/\bK1\b/, :from, true], [/\bK37\b/, :to, true]],
        ["edge_add", "self-derivation"]    => [[/\bK37\b/, :alias, true]],
        ["edge_add", "wrong-endpoint"]     => [[/got evidence/, :got, false]],
        # frontier_add
        ["frontier_add", "frontier-re-add"]  => [[/\bK1\b/, :alias, true]],
        ["frontier_add", "duplicate-need"]   => [[/"[^"]+" on K2/, :located, false]],
        ["frontier_add", "score-range"]      => [],
        ["frontier_add", "unknown-node"]     => ID_SLOT,
        # frontier_close
        ["frontier_close", "no-open-entry"]    => [[/\bK1\b/, :alias, true]],
        ["frontier_close", "closure-violation"] => [[/\bK7\b/, :alias, true]],
        # list
        ["list", "unknown-label"] => [[/UNKNOWN-LABEL: \w+/, :named, false]],
        # neighbors / node_get / paths
        ["neighbors", "unknown-node"] => ID_SLOT,
        ["node_get", "unknown-node"]  => ID_SLOT,
        ["paths", "unknown-node"]     => ID_SLOT,
        ["paths", "depth-cap"]        => [[/depth \d+/, :depth, false]],
        # node_add
        ["node_add", "duplicate-label"]      => [[/\bK12\b/, :existing, true]],
        ["node_add", "duplicate-span"]       => [[/E7 on C13/, :located, false]],
        ["node_add", "unanchored-span"]      => [[/nearest fragments: "[^"]*" \| "[^"]*"/, :fragments, false],
                                                 [/lines \d+–\d+/, :junction, false],
                                                 [/blob of C13/, :src_seg, false]],
        ["node_add", "span-beyond-snapshot"] => [[/offsets \d+\.\.\d+/, :offsets, false],
                                                 [/length \d+/, :length, false],
                                                 [/\bC13\b/, :src, true]],
        ["node_add", "agenda-source"]        => [[/\bC5\b/, :src, true]],
        ["node_add", "unknown-field"]        => [[/UNKNOWN-FIELD: \w+ is not/, :named, false],
                                                 [/is not a field of \w+/, :of, false],
                                                 [/legal fields: [^;]+/, :legal, false]],
        ["node_add", "fused-shape"]          => [],
        ["node_add", "fused-direction"]      => [],
        ["node_add", "terminal-shape"]       => [],
        # node_set
        ["node_set", "unknown-field"]        => [[/UNKNOWN-FIELD: \w+ is not/, :named, false],
                                                 [/is not a field of \w+/, :of, false],
                                                 [/legal fields: [^;]+/, :legal, false]],
        ["node_set", "flat-nested-collision"] => [[/\w+ given twice \(flat "[^"]*" and fields: "[^"]*"\)/,
                                                   :collision, false]],
        ["node_set", "dual-arm"]             => [[/\bK37\b/, :alias, true]],
        ["node_set", "stamped-field"]        => [],
        ["node_set", "unknown-node"]         => ID_SLOT,
        # report_draft
        ["report_draft", "section-too-large"] => [[/capped at \d+ chars/, :cap, false]],
        ["report_draft", "version-frozen"]    => [[/version \d+/, :version, false]],
        ["report_draft", "phase-not-synthesis"] => [[/decompose\(1\/1\)/, :phase, false]],
        # report_bind
        ["report_bind", "ordinal-unbound"]    => [[/\[\^\d+\]/, :ordinal, false],
                                                  [/holds \d+ sources \(ordinals 1\.\.\d+/, :corpus, false],
                                                  [/holds \d+ more/, :imports, false]],
        ["report_bind", "import-unmarked"]    => [[/\[\^\d+\]/, :ordinal, false]],
        ["report_bind", "hash-transcription"] => [],
        # retrieve / search
        ["retrieve", "model-name-refused"] => [],
        ["search", "id-probe"]             => [],
        # source_grep
        ["source_grep", "unknown-source"]    => [[/\bC99\b/, :src, true]],
        ["source_grep", "pattern-required"]  => [],
        # source_read
        ["source_read", "non-sliced-read"]   => [[/\bC13\b/, :src, true],
                                                 [/cap \d+ chars\/slice/, :cap_seg, false]],
        ["source_read", "unknown-source"]    => [[/\bC99\b/, :src, true]],
        ["source_read", "offset-beyond-eof"] => [[/offset \d+/, :offset, false],
                                                 [/\d+ lines/, :lines, true],
                                                 [/1\.\.\d+/, :range, false]],
        # subagent_spawn / subagent_status
        ["subagent_spawn", "profile-unknown"] => [[/PROFILE-UNKNOWN: \w+/, :named, false]],
        ["subagent_spawn", "band-overlap"]    => [[/overlaps K\d+–K\d+/, :overlap, false]],
        ["subagent_status", "unknown-run"]    => [[/run run\/\S+/, :run, false]],
        # web_search / web_fetch
        ["web_search", "budget-exceeded"] => BUDGET_LINE,
        ["web_fetch", "budget-exceeded"]  => BUDGET_LINE,
        ["web_fetch", "duplicate-fetch"]  => [[/\bC14\b/, :src, true],
                                              [/"[^"]+" — never re-fetch/, :title_seg, false]]
      }.freeze

      # ── the §3.9 SUCCESS-NOTE texts (pinned constants — NOT fixture
      #    sections; byte-pinned by texts_test.rb against DESIGN.md §3.9
      #    parsed at runtime; the landed I13 pattern) ──────────────────────

      # bare note (a claim created satisfying nothing):
      BARE_NOTE = "(satisfies nothing — add terminal, derives_from, or frontier_add before the phase gate)"

      # unreferenced note (a claim created with no evidence):
      UNREFERENCED_NOTE = "(unreferenced — claims need ≥1 evidence node before the phase gate)"

      # coercion note (a coerced success; <what> = e.g. "terminal:string→object"):
      COERCION_NOTE = "(coerced %<what>s — the tool-call layer stringified a complex value; " \
                      "nest it under fields: to avoid)"

      # dedup-candidates note (near hits; candidates pre-rendered by the tool
      # as "K<m> (near_dup, cosine <c>)" segments joined with ", "):
      DEDUP_NOTE_TAIL = "attach evidence to the existing claim or reword if genuinely distinct; " \
                        "nothing is " \
                        "auto-merged"
      DEDUP_CANDIDATES_NOTE = "dedup candidates: [%<candidates>s] — #{DEDUP_NOTE_TAIL}"

      # budget echo (every web result):
      BUDGET_ECHO_NOTE = "web_calls=%<used>s/%<cap>s"

      # cap-continuation note (every capped listing):
      CAP_NOTE = "(capped at %<n>s rows — resume with after:\"%<last_id>s\"; " \
                 "ordering is principled, never shuffled)"

      module_function

      def bare_note = BARE_NOTE
      def unreferenced_note = UNREFERENCED_NOTE
      def coercion_note(what) = format(COERCION_NOTE, what: what)
      def dedup_candidates_note(candidates) = format(DEDUP_CANDIDATES_NOTE, candidates: candidates)
      def budget_echo_note(used:, cap:) = format(BUDGET_ECHO_NOTE, used: used, cap: cap)
      def cap_note(n:, last_id:) = format(CAP_NOTE, n: n, last_id: last_id)
    end
  end
end
