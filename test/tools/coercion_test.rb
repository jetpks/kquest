# frozen_string_literal: true

require_relative "texts_test"

# The T1–T6 coercion battery (I05 §4 / DR-02), re-expressed against the I01
# schema: parse ONCE at the boundary, the PARSED value is what every storage
# site STORES (write-back), coerced successes carry the frozen note; garbage
# leaves the refusal voice unchanged; a JSON-looking string-RULE value is
# stored verbatim (T6).
class CoercionTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/node_add.md", __dir__)

  def setup
    mint
    @add = build_tool("node_add")
    @set = build_tool("node_set")
  end

  # T1: stringified fused array → coerced + taught + stored parsed
  def test_T1_stringified_fused_array_coerced_taught_stored_parsed
    source = mint_source(snapshot: "a fixture snapshot line for T1\n")
    answer = execute_tool(@add, label: "evidence", src: "C1",
                          span: "a fixture snapshot line for T1",
                          reading: "the T1 reading",
                          supports_new: "[{\"text\":\"the T1 fused claim\"}]")

    claim = conn[:claims].where(quest_id: @quest_id).first
    refute_nil claim, "the fused claim was created from the stringified array"
    assert_equal "the T1 fused claim", claim[:text], "the PARSED value is stored (write-back)"
    assert_includes answer, Kquest::Tools::Texts.coercion_note("supports_new:string→array")
  end

  # T2: stringified edge array (the supports list) → coerced + wired
  def test_T2_stringified_edge_array_coerced_and_wired
    claim = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                        text: "an existing claim")
    source = mint_source(snapshot: "a fixture snapshot line for T2\n")
    execute_tool(@add, label: "evidence", src: "C1",
                 span: "a fixture snapshot line for T2", reading: "r",
                 supports: "[\"K1\"]")
    edge = conn[:evidence_edges].where(claim_id: claim).first
    refute_nil edge, "the stringified supports array coerced into the edge"
  end

  # T3: stringified object field → coerced + stored parsed
  def test_T3_stringified_object_field_coerced_and_stored_parsed
    claim = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                        text: "a claim to type")
    execute_tool(@set, node: "K1",
                 terminal: "{\"type\":\"residual-uncertainty\",\"basis\":\"the T3 basis\"}")
    row = conn[:claims].where(id: claim).first
    assert_equal "residual-uncertainty", row[:terminal_type], "the PARSED object stored"
    assert_equal "the T3 basis", row[:terminal_basis]
  end

  # T4: garbage refused with the refusal voice unchanged
  def test_T4_garbage_leaves_the_refusal_voice_unchanged
    assert_raises(Kquest::Engine::Error) do
      execute_tool(@add, label: "claim", text: "t", terminal: "{broken json:: no parse")
    end
  end

  # T5: plain-string edge value refused (no coercion of non-JSON strings)
  def test_T5_plain_string_edge_refused
    claim = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                        text: "a claim")
    source = mint_source(snapshot: "a fixture snapshot line for T5\n")
    produced = assert_raises(Kquest::Engine::Error) do
      execute_tool(@add, label: "evidence", src: "C1",
                   span: "a fixture snapshot line for T5", reading: "r",
                   supports: "K1")
    end
    assert_equal "FUSED-SHAPE", produced.error_class
  end

  # T6: a JSON-looking string-RULE value is stored verbatim (never coerced —
  # a String FIELD value that parses stays a String at storage)
  def test_T6_json_looking_string_rule_value_stored_verbatim
    claim = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                        text: "a claim with a quoted field value")
    execute_tool(@set, node: "K1", text: "{\"looks\":\"like json\"}")
    row = conn[:claims].where(id: claim).first
    assert_equal "{\"looks\":\"like json\"}", row[:text], "the string value stored VERBATIM (T6)"
  end
end
