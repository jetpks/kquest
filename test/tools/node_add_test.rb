# frozen_string_literal: true

require_relative "texts_test"
require_relative "../support/mock_embeddings_server"

# node_add — fused creation (the fixture IS the acceptance test; every
# refusal class a named byte-match test — AC3).
class NodeAddTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/node_add.md", __dir__)

  def setup
    mint
    @claims_text = "Momentum profits persist after controlling for market beta in the fixture literature."
  end

  # ── the claim form ──────────────────────────────────────────────────────

  def test_claim_creation_mints_alias_urn_and_embed_job
    tool = build_tool("node_add")
    answer = execute_tool(tool, label: "claim", text: @claims_text)
    claim = conn[:claims].where(quest_id: @quest_id).first

    assert claim
    assert_equal 1, claim[:quest_seq]
    assert_match(/\AK1 created/, answer)
    assert_match(/\Akb:claim:[1-9A-HJ-NP-Za-km-z]{10}\z/, claim[:urn])
    job = conn[:embed_jobs].where(quest_id: @quest_id, kind: "embed", target_kind: "claim").first
    refute_nil job, "a successful claim creation mints the quest-level idem-keyed claim embed job"
    assert_equal "embed:#{Kquest::Tools::DEFAULT_CONFIG.fetch('tools.claim_embedding_model')}:claim:quest:#{@quest_id}",
                 job[:idem_key]
  end

  def test_claim_created_satisfying_nothing_carries_the_frozen_notes
    tool = build_tool("node_add")
    answer = execute_tool(tool, label: "claim", text: @claims_text)
    assert_includes answer, Kquest::Tools::Texts.bare_note
    assert_includes answer, Kquest::Tools::Texts.unreferenced_note
  end

  def test_typed_claim_carries_the_bare_note_never_the_unreferenced_one_absent
    tool = build_tool("node_add")
    answer = execute_tool(tool, label: "claim", text: @claims_text,
                          terminal: {"type" => "primary-empirical", "basis" => "the fixture corpus"})
    refute_includes answer, Kquest::Tools::Texts.bare_note
    assert_includes answer, Kquest::Tools::Texts.unreferenced_note
  end

  def test_duplicate_label_refuses_byte_matched
    tool = build_tool("node_add")
    execute_tool(tool, label: "claim", text: @claims_text)

    assert_refusal("node_add", "duplicate-label", slots: {existing: "K1"}, planted: ["K1"]) do
      execute_tool(tool, label: "claim", text: @claims_text)
    end
    assert_equal 1, conn[:claims].where(quest_id: @quest_id).count, "a refusal creates nothing"
  end

  def test_unknown_field_refusal_composes_legal_fields_and_hint
    tool = build_tool("node_add")
    assert_refusal("node_add", "unknown-field",
                   slots: {named: "UNKNOWN-FIELD: basis is not", of: "is not a field of claim",
                           legal: "legal fields: text, terminal"},
                   planted: ["basis"]) do
      execute_tool(tool, label: "claim", text: @claims_text, basis: "stray")
    end
  end

  def test_terminal_shape_refusal
    tool = build_tool("node_add")
    assert_refusal("node_add", "terminal-shape", slots: {}) do
      execute_tool(tool, label: "claim", text: @claims_text, terminal: {"type" => "vibes", "basis" => "x"})
    end
  end

  # ── the evidence form (fused) ───────────────────────────────────────────

  def snapshot_text
    <<~TEXT
      line one of the fixture snapshot
      line two of the fixture snapshot
      line three of the fixture snapshot mentions Brinson
      line four of the fixture snapshot
      line five of the fixture snapshot
    TEXT
  end

  def source_with_span(span)
    snapshot = snapshot_text
    refute_nil snapshot.index(span), "test span must be byte-present"
    mint_source(snapshot: snapshot)
  end

  def test_fused_evidence_creates_evidence_claims_edges_atomically
    source = source_with_span("line three of the fixture snapshot mentions Brinson")
    tool = build_tool("node_add")
    answer = execute_tool(tool, label: "evidence", src: "C1",
                          span: "line three of the fixture snapshot mentions Brinson",
                          reading: "the fixture snapshot's third line",
                          supports_new: [{"text" => @claims_text}])

    evidence = conn[:evidence].where(quest_id: @quest_id).first
    claim = conn[:claims].where(quest_id: @quest_id).first
    edge = conn[:evidence_edges].where(quest_id: @quest_id).first
    assert evidence
    assert_equal source[:id], evidence[:source_id]
    assert_equal "line three of the fixture snapshot mentions Brinson".length,
                 evidence[:span_end] - evidence[:span_start]
    assert claim, "the fused form creates the claim"
    assert edge, "and the edge"
    assert_equal "supports", edge[:relation]
    assert_includes answer, "K1"
    assert_includes answer, "E1"
  end

  def test_duplicate_span_refuses_byte_matched
    source = source_with_span("line three of the fixture snapshot mentions Brinson")
    tool = build_tool("node_add")
    execute_tool(tool, label: "evidence", src: "C1",
                 span: "line three of the fixture snapshot mentions Brinson",
                 reading: "r", supports_new: [{"text" => @claims_text}])

    assert_refusal("node_add", "duplicate-span", slots: {located: "E1 on C1"}, planted: ["E1", "C1"]) do
      execute_tool(tool, label: "evidence", src: "C1",
                   span: "line three of the fixture snapshot mentions Brinson",
                   reading: "r2")
    end
  end

  def test_unanchored_span_refusal_locates_fragments_and_junction
    source = source_with_span("line three of the fixture snapshot mentions Brinson")
    tool = build_tool("node_add")
    # a re-flowed span (the §3.8 defect): joined across the line junction
    reflowed = "fixture snapshot line three of the fixture snapshot mentions"
    produced = assert_refusal("node_add", "unanchored-span",
                              slots: {fragments: refergent_fragments(reflowed, source),
                                      junction: refergent_junction(reflowed, source),
                                      src_seg: "blob of #{source[:urn]}"},
                              planted: [source[:urn]]) do
      execute_tool(tool, label: "evidence", src: "C1", span: reflowed, reading: "r")
    end
    _ = produced
  end

  # The locating algorithm's own output (the nearest whitespace-normalized
  # fragments + the line junction), recomputed here so the byte-match is
  # against the frozen line WITH the tool's located slots.
  def refergent_fragments(span, source)
    frag1 = span.gsub(/\s+/, " ")[0, 40].to_s.strip
    frag2 = span.gsub(/\s+/, " ")[-40, 40].to_s.strip
    "nearest fragments: \"#{frag1}\" | \"#{frag2}\""
  end

  def refergent_junction(_span, _source)
    "lines 1–2"
  end

  def test_span_beyond_snapshot_refusal_names_actual_length
    source = source_with_span("line three of the fixture snapshot mentions Brinson")
    tool = build_tool("node_add")
    assert_refusal("node_add", "span-beyond-snapshot",
                   slots: {offsets: "offsets 0..999999", length: "length #{snapshot_text.length}",
                           src: source[:urn]},
                   planted: [snapshot_text.length.to_s]) do
      execute_tool(tool, label: "evidence", src: "C1", span_start: 0, span_end: 999_999,
                   reading: "r")
    end
  end

  def test_agenda_source_refusal
    source = mint_source(snapshot: snapshot_text, role: "agenda")
    tool = build_tool("node_add")
    assert_refusal("node_add", "agenda-source", slots: {src: "C1"}, planted: ["C1"]) do
      execute_tool(tool, label: "evidence", src: "C1",
                   span: "line three of the fixture snapshot mentions Brinson", reading: "r")
    end
    _ = source
  end

  def test_fused_direction_refusal_on_claim_side_supports_new
    tool = build_tool("node_add")
    assert_refusal("node_add", "fused-direction", slots: {}) do
      execute_tool(tool, label: "claim", text: @claims_text,
                   supports_new: [{"text" => "something"}])
    end
  end

  def test_fused_shape_refusal_on_garbage_supports_new
    source = source_with_span("line three of the fixture snapshot mentions Brinson")
    tool = build_tool("node_add")
    assert_refusal("node_add", "fused-shape", slots: {}) do
      execute_tool(tool, label: "evidence", src: "C1",
                   span: "line three of the fixture snapshot mentions Brinson",
                   reading: "r", supports_new: "not-a-json-array")
    end
  end

  # ── the dedup candidate check (I03 family d at the tool) ────────────────

  def test_exact_leg_blind_to_near_duplicates_near_leg_surfaces_the_note
    mock = MockEmbeddingsServer.new.start
    cfg = mock_registry_config(mock)
    mock.script([{type: :embeddings, vectors: [Array.new(384) { |i| (i % 97) / 97.0 * 0.9 + 0.01 }]}])

    # the existing claim + its vector (the near-dup family member)
    existing = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                           text: "Net-of-cost momentum persists modestly once the cost assumptions are applied.")
    mock.script([{type: :embeddings, vectors: [Array.new(384) { |i| (i % 97) / 97.0 * 0.9 + 0.01 }]}])
    mint_claim_vector(existing, Array.new(384) { |i| (i % 97) / 97.0 * 0.9 + 0.01 })

    tool = build_tool("node_add", config: cfg)
    answer = execute_tool(tool, label: "claim",
                          text: "Net-of-cost momentum persists modestly once the cost assumptions are used here.")

    assert_includes answer, Kquest::Tools::Texts.dedup_candidates_note("K1 (near_dup, cosine 1.0)"),
                    "near-dups NEVER refuse — the frozen note surfaces them"
    assert_equal 2, conn[:claims].where(quest_id: @quest_id).count
  ensure
    mock&.stop
  end

  def test_stringified_terminal_is_coerced_stored_parsed_and_taught
    source = source_with_span("line three of the fixture snapshot mentions Brinson")
    tool = build_tool("node_add")
    answer = execute_tool(tool, label: "claim", text: @claims_text,
                          terminal: "{\"type\":\"primary-empirical\",\"basis\":\"the fixture corpus\"}")
    claim = conn[:claims].where(quest_id: @quest_id).first
    assert_equal "primary-empirical", claim[:terminal_type], "the PARSED value is stored (write-back)"
    assert_equal "the fixture corpus", claim[:terminal_basis]
    assert_includes answer, Kquest::Tools::Texts.coercion_note("terminal:string→object")
  end
end
