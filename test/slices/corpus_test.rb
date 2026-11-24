# frozen_string_literal: true

require_relative "../test_helper"

# The corpus slice: boots its own :db provider, carries the six pinned
# relation keys (I08 §1 slice map / I11 Part 5), and its aggregate-root repo
# round-trips by_pk against the migrated kquest_test.
class SlicesCorpusTest < Minitest::Test
  def conn
    @conn ||= Kquest::App["db.gateway"].connection
  end

  def slice
    @slice ||= Kquest::App.slices.to_a.find { |s| s.slice_name.to_s == "corpus" }
  end

  def rom
    @rom ||= slice["db.rom"]
  end

  def test_slice_boots
    refute_nil slice
  end

  def test_pinned_relations_resolve_and_count
    %w[sources quest_sources chunk_strategies chunks unmined_sources decompose_remaining]
      .each do |key|
        count = rom.relations[key].count
        assert count >= 0, "relation #{key} did not resolve"
      end
  end

  def test_chunk_strategies_repo_round_trip
    id = SecureRandom.uuid
    conn[:chunk_strategies].insert(
      id: id, name: "test-strategy", version: 1,
      target_chars: 100, overlap_chars: 0, paragraph_aligned: false
    )
    found = slice["repos.chunk_strategies_repo"].by_pk(id)
    refute_nil found, "ChunkStrategiesRepo#by_pk did not find the row"
    assert_equal "test-strategy", found.name
  ensure
    conn[:chunk_strategies].where(id: id).delete
  end
end
