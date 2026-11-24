# frozen_string_literal: true

require_relative "../tools/texts_test"

# neighborhood — I01 Q3, transcribed.
class NeighborhoodQueryTest < Minitest::Test
  include ToolRig

  def setup
    mint
    @k1 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1, text: "center claim")
    @k2 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 2, text: "parent claim")
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: @k1,
                                    parent_claim_id: @k2, position: 1)
    @query = Kquest::Queries::Neighborhood.new(conn: conn)
  end

  # the frozen family property (AC4)
  def test_neighborhood_bounded_cycle_safe_walk
    # wire the cycle K1 → K2 → K1 explicitly — the walk must survive it
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: @k2,
                                    parent_claim_id: @k1, position: 1)
    rows = @query.hood(@k1, user_id: @user_id, quest_id: @quest_id, radius: 2)
    kinds = rows.map { |r| r[:node_kind] }
    assert_kind_of Array, rows
    assert rows.any? { |r| r[:node_id] == @k2 }, "the parent is in the hood"
    assert rows.all? { |r| r[:depth] <= 2 }, "the walk is bounded by the radius"
    assert_equal rows.map { |r| [r[:node_kind], r[:node_id]] }.sort,
                 rows.map { |r| [r[:node_kind], r[:node_id]] }.sort.uniq, "cycle-safe (deduped)"
    _ = kinds
  end

  def test_direction_filter
    # "in" = only the children arm (who derives from K1): the parent is unseen
    rows = @query.hood(@k1, user_id: @user_id, quest_id: @quest_id, radius: 2, direction: "in")
    refute rows.any? { |r| r[:node_id] == @k2 && r[:node_kind] == "claim" },
           "an in-only walk from the child sees no parent"
    rows = @query.hood(@k1, user_id: @user_id, quest_id: @quest_id, radius: 2, direction: "out")
    assert rows.any? { |r| r[:node_id] == @k2 }, "an out walk follows derives_from to the parent"
  end

  def test_radius_bound
    k3 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 3, text: "grandparent")
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: @k2,
                                    parent_claim_id: k3, position: 1)
    rows = @query.hood(@k1, user_id: @user_id, quest_id: @quest_id, radius: 1)
    refute rows.any? { |r| r[:node_id] == k3 }, "radius 1 stops at the parent"
  end

  # The I17 fix (judge Finding 7): the WALKED node carries its OWN node_kind
  # (the parent's kind labeled every node before). A claim→evidence edge
  # must surface the evidence node as kind 'evidence', and the evidence→source
  # leg as kind 'source' — the cross_kind walk.
  def test_cross_kind_walk_labels_each_walked_node_with_its_own_kind
    text = "the span text"
    source = mint_source(snapshot: text)
    evidence_id = conn[:evidence].insert(
      user_id: @user_id, quest_id: @quest_id, source_id: source[:id],
      source_anchorable: true, snapshot_char_count: text.length,
      span_start: 0, span_end: text.length, span_text: text, reading: "the reading"
    )
    conn[:evidence_edges].insert(user_id: @user_id, quest_id: @quest_id,
                                 evidence_id: evidence_id, claim_id: @k1,
                                 relation: "supports", position: 1)
    rows = @query.hood(@k1, user_id: @user_id, quest_id: @quest_id, radius: 2)
    kinds = rows.to_h { |r| [r[:node_id], r[:node_kind]] }
    assert_equal "claim", kinds[@k1], "the center is a claim"
    assert_equal "claim", kinds[@k2], "the derivation parent is a claim"
    assert_equal "evidence", kinds[evidence_id],
                 "the cross_kind edge labels the walked evidence node with ITS OWN kind"
  end
end
