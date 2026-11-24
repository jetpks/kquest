# frozen_string_literal: true

require_relative "../tools/texts_test"

# citation_ancestry — I01 Q2 (L3 independence data), transcribed.
class CitationAncestryQueryTest < Minitest::Test
  include ToolRig

  def setup
    mint
    @k1 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1, text: "ancestor claim")
    @k2 = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 2, text: "descendant claim")
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: @k2,
                                    parent_claim_id: @k1, position: 1)
    @source = mint_source(snapshot: "shared source snapshot\n")
    @e1 = mint_evidence(@source)
    @e2 = mint_evidence(@source)
    conn[:evidence_edges].insert(user_id: @user_id, quest_id: @quest_id, evidence_id: @e1,
                                 relation: "supports", claim_id: @k1, position: 1)
    conn[:evidence_edges].insert(user_id: @user_id, quest_id: @quest_id, evidence_id: @e2,
                                 relation: "supports", claim_id: @k2, position: 1)
    @query = Kquest::Queries::CitationAncestry.new(conn: conn)
  end

  def mint_evidence(source)
    @evidence_count = (@evidence_count || 0) + 1
    start = (@evidence_count - 1) * 6
    conn[:evidence].insert(
      user_id: @user_id, quest_id: @quest_id, source_id: source[:id], source_anchorable: true,
      snapshot_char_count: source[:text].length, span_start: start, span_end: start + 6,
      span_text: source[:text][start, 6], reading: "a reading"
    )
  end

  # the frozen family property (AC4)
  def test_ancestry_dependent_evidence_pairs
    rows = @query.dependent_pairs(user_id: @user_id, quest_id: @quest_id)
    pair = rows.find { |r| r[:claim_id] == @k2 && r[:ancestor_claim_id] == @k1 }
    refute_nil pair, "the ancestor/descendant pair sharing a source is dependent"
    assert_equal @source[:id], pair[:shared_source_id]
  end

  def test_same_claim_same_source_pairs_appear_once_per_unordered_pair
    # the frozen Q2 law: the reflexive depth-0 arm matches both orientations;
    # the id filter on that arm alone keeps exactly ONE row per unordered pair
    e3 = mint_evidence(@source)
    conn[:evidence_edges].insert(user_id: @user_id, quest_id: @quest_id, evidence_id: e3,
                                 relation: "supports", claim_id: @k1, position: 2)
    rows = @query.dependent_pairs(user_id: @user_id, quest_id: @quest_id)
    same_claim = rows.select { |r| r[:ancestor_depth].zero? && r[:claim_id] == @k1 }
    assert_equal 1, same_claim.size, "exactly one orientation per unordered pair"
  end

  def test_user_scoping_is_a_parameter
    other = PipelineFixtures.mint_tenancy(conn)
    assert_empty @query.dependent_pairs(user_id: other[:user_id], quest_id: other[:quest_id])
    PipelineFixtures.cleanup(conn, user_id: other[:user_id])
  end
end
