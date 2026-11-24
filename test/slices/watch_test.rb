# frozen_string_literal: true

require_relative "../test_helper"

# The watch slice is the EMPTY scaffold this iteration (I11 Part 5): its
# surfaces — SSE producers, metrics, alert queries — are ENTRY 4/5 consumers.
# Pinned: the slice exists and boots, and carries no relations.
class SlicesWatchTest < Minitest::Test
  def slice
    @slice ||= Kquest::App.slices.to_a.find { |s| s.slice_name.to_s == "watch" }
  end

  def test_slice_boots
    refute_nil slice
  end

  def test_watch_has_no_relations_this_iteration
    keys = slice["db.rom"].relations.to_hash.keys
    assert_empty keys, "watch carries relations; this iteration pins it empty"
  end
end
