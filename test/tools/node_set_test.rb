# frozen_string_literal: true

require_relative "texts_test"

# node_set — field updates on one node (the fixture IS the acceptance test).
class NodeSetTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/node_set.md", __dir__)

  def setup
    mint
    @claim = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                         text: "the original claim text")
    @tool = build_tool("node_set")
  end

  def test_flat_text_update
    answer = execute_tool(@tool, node: "K1", text: "the updated claim text")
    assert_equal "the updated claim text", conn[:claims].where(id: @claim).first[:text]
    assert_includes answer, "K1 updated"
  end

  def test_nested_fields_update_and_the_coercion_write_back
    answer = execute_tool(@tool, node: "K1", fields: {text: "nested update"})
    assert_equal "nested update", conn[:claims].where(id: @claim).first[:text]

    # a stringified terminal is coerced, the PARSED object stored (write-back)
    execute_tool(@tool, node: "K1", fields: {terminal: "{\"type\":\"primary-empirical\",\"basis\":\"b\"}"})
    claim = conn[:claims].where(id: @claim).first
    assert_equal "primary-empirical", claim[:terminal_type]
    assert_equal "b", claim[:terminal_basis]
    _ = answer
  end

  def test_unknown_field_refusal_byte_matched
    assert_refusal("node_set", "unknown-field",
                   slots: {named: "UNKNOWN-FIELD: newText is not", of: "is not a field of claim",
                           legal: "legal fields: text, terminal"},
                   planted: ["newText"]) do
      execute_tool(@tool, node: "K1", newText: "x")
    end
  end

  def test_flat_nested_collision_refusal_byte_matched
    assert_refusal("node_set", "flat-nested-collision",
                   slots: {collision: "text given twice (flat \"flat-value\" and fields: \"nested-value\")"},
                   planted: ["flat-value", "nested-value"]) do
      execute_tool(@tool, node: "K1", text: "flat-value", fields: {text: "nested-value"})
    end
  end

  def test_dual_arm_refusal_byte_matched
    parent = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 2,
                                         text: "the parent claim")
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: @claim,
                                    parent_claim_id: parent, position: 1)

    assert_refusal("node_set", "dual-arm", slots: {alias: "K1"}, planted: ["K1"]) do
      execute_tool(@tool, node: "K1",
                   terminal: {"type" => "residual-uncertainty", "basis" => "b"})
    end
  end

  def test_stamped_field_refusal_byte_matched
    assert_refusal("node_set", "stamped-field", slots: {}, planted: []) do
      execute_tool(@tool, node: "K1", urn: "kb:claim:AAAAAAAAA1")
    end
  end

  def test_unknown_node_refusal_byte_matched
    assert_refusal("node_set", "unknown-node", slots: {id: "K99"}, planted: ["K99"]) do
      execute_tool(@tool, node: "K99", text: "x")
    end
  end
end
