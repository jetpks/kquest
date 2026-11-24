# frozen_string_literal: true

require_relative "../test_helper"

# The quest slice: the fourteen pinned relation keys (tenancy chain, the I06
# CONFIG TABLES, ladder_passes, and the lineage/visibility views).
class SlicesQuestTest < Minitest::Test
  def conn
    @conn ||= Kquest::App["db.gateway"].connection
  end

  def slice
    @slice ||= Kquest::App.slices.to_a.find { |s| s.slice_name.to_s == "quest" }
  end

  def rom
    @rom ||= slice["db.rom"]
  end

  def test_slice_boots
    refute_nil slice
  end

  def test_pinned_relations_resolve_and_count
    %w[quests phases sessions tool_calls usage_events quest_lifecycle_events
       quest_lineage workspaces workspace_members resource_grants
       resource_visibility phase_transitions stop_rules ladder_passes].each do |key|
      count = rom.relations[key].count
      assert count >= 0, "relation #{key} did not resolve"
    end
  end

  def test_quests_repo_round_trip
    user_id = SecureRandom.uuid
    conn[:users].insert(
      id: user_id, handle: "gh-quest-test", github_uid: "quest-test-uid",
      username: "quest-test", created_at: Time.now, updated_at: Time.now
    )
    quest_id = SecureRandom.uuid
    conn[:quests].insert(
      id: quest_id, user_id: user_id, topic: "quest slice round-trip",
      web_call_budget: 1, token_budget: 1, spend_budget_usd: 0
    )
    found = slice["repos.quests_repo"].by_pk(quest_id)
    refute_nil found, "QuestsRepo#by_pk did not find the row"
    assert_equal "active", found.state
  ensure
    conn[:quests].where(id: quest_id).delete
    conn[:users].where(id: user_id).delete
  end

  # PhaseTransitionsRepo: the ENTRY 4 phase runner's ordered config read —
  # the seeded rows come back in file order (ordinal 1..27).
  def test_phase_transitions_repo_reads_seeded_rows_in_file_order
    rows = slice["repos.phase_transitions_repo"]
             .phase_transitions.order(:ordinal).to_a
    assert_equal 27, rows.size
    assert_equal 1, rows.first.ordinal
    assert_equal "graph_invalid", rows.first.event
  end
end
