# frozen_string_literal: true

require_relative "../test_helper"

# The graph slice: the twelve pinned relation keys (nine base tables + the
# I01/I02 law views) over the migrated kquest_test.
class SlicesGraphTest < Minitest::Test
  def conn
    @conn ||= Kquest::App["db.gateway"].connection
  end

  def slice
    @slice ||= Kquest::App.slices.to_a.find { |s| s.slice_name.to_s == "graph" }
  end

  def rom
    @rom ||= slice["db.rom"]
  end

  def test_slice_boots
    refute_nil slice
  end

  def test_pinned_relations_resolve_and_count
    %w[claims evidence evidence_edges claim_derivations frontier_entries conflicts
       conflict_sources canonical_claims frontier_open frontier_mass claim_closure
       quest_graph_fingerprint].each do |key|
      count = rom.relations[key].count
      assert count >= 0, "relation #{key} did not resolve"
    end
  end

  def test_claims_repo_round_trip
    user_id = SecureRandom.uuid
    conn[:users].insert(
      id: user_id, handle: "gh-graph-test", github_uid: "graph-test-uid",
      username: "graph-test", created_at: Time.now, updated_at: Time.now
    )
    quest_id = SecureRandom.uuid
    conn[:quests].insert(
      id: quest_id, user_id: user_id, topic: "graph slice round-trip",
      web_call_budget: 1, token_budget: 1, spend_budget_usd: 0
    )
    claim_id = SecureRandom.uuid
    conn[:claims].insert(
      id: claim_id, user_id: user_id, quest_id: quest_id, quest_seq: 1,
      text: "The graph slice reads claims through ROM.",
      urn: "kb:claim:abcdefghij"
    )
    found = slice["repos.claims_repo"].by_pk(claim_id)
    refute_nil found, "ClaimsRepo#by_pk did not find the row"
    # canonical_text is the I01 DR-05 generated normalization.
    assert_equal "The graph slice reads claims through ROM.", found.canonical_text
  ensure
    conn[:claims].where(id: claim_id).delete
    conn[:quests].where(id: quest_id).delete
    conn[:users].where(id: user_id).delete
  end
end
