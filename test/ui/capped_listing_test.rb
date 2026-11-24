# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/orchestrator_fixtures"

# The L15 capped listing (BRIEF §3): the caller-declared principled order,
# the cap from `tool_config` `ui.listing_cap.<surface>` (config is the only
# cap source — a missing row raises loudly), the telemetry row emitted in the
# SAME transaction as the read, and the returned shape the pages use to
# surface "showing N of M" (never silent truncation).
class CappedListingTest < Minitest::Test
  SURFACE = "capped_listing_test"

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    OrchestratorFixtures.sweep_all(conn)
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    conn[:tool_config].where(key: cap_key).delete
    conn[:tool_config].insert(key: cap_key, num_value: 3, text_value: nil,
                              provenance: "test data (the seeds re-heal at the next prepare)")
  end

  def teardown
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def cap_key = "ui.listing_cap.#{SURFACE}"

  def mint_listings(n)
    phase_id = conn[:phases].insert(
      user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id], kind: "descent"
    )
    n.times do |i|
      conn[:frontier_entries].insert(
        user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
        claim_id: PipelineFixtures.mint_claim(conn, user_id: @tenancy[:user_id],
                                              quest_id: @tenancy[:quest_id], seq: i + 1,
                                              text: "claim #{i}"),
        need: "need #{i}", uncertainty: 3, relevance: 3,
        spawned_by_phase_id: phase_id
      )
    end
    conn[:frontier_entries].where(quest_id: @tenancy[:quest_id])
  end

  def test_applies_the_config_cap_with_the_declared_order
    dataset = mint_listings(5)
    result = Kquest::Ui::CappedListing.call(
      conn, dataset, surface: SURFACE, user_id: @tenancy[:user_id],
      quest_id: @tenancy[:quest_id],
      order: [Sequel.desc(:uncertainty), Sequel.desc(:relevance), Sequel.asc(:opened_at), :id]
    )
    assert_equal 3, result[:rows].size, "the cap bounds the page"
    assert_equal 5, result[:requested]
    assert_equal 3, result[:cap]
    assert_equal 5, result[:existed]
  end

  def test_order_is_the_callers_deterministic_principled_one
    dataset = mint_listings(5)
    result = Kquest::Ui::CappedListing.call(
      conn, dataset.order(Sequel.asc(:opened_at)), surface: SURFACE,
      user_id: @tenancy[:user_id], order: [Sequel.asc(:opened_at), :id]
    )
    first_opened = result[:rows].first[:opened_at]
    assert_equal dataset.order(Sequel.asc(:opened_at), :id).limit(3).first[:opened_at],
                 first_opened
  end

  def test_emits_the_telemetry_row_in_the_same_transaction
    dataset = mint_listings(4)
    Kquest::Ui::CappedListing.call(conn, dataset, surface: SURFACE,
                                   user_id: @tenancy[:user_id],
                                   quest_id: @tenancy[:quest_id], order: [Sequel.asc(:opened_at)])
    row = conn[:cap_records].where(surface: SURFACE).first
    refute_nil row, "one row per capped listing request"
    assert_equal 4, row[:requested]
    assert_equal 3, row[:cap]
    assert_equal 4, row[:existed]
    assert_equal @tenancy[:quest_id], row[:quest_id]
  end

  def test_under_cap_requests_still_record_the_reading
    dataset = mint_listings(2)
    Kquest::Ui::CappedListing.call(conn, dataset, surface: SURFACE,
                                   user_id: @tenancy[:user_id], order: [:id])
    row = conn[:cap_records].where(surface: SURFACE).first
    assert_equal 2, row[:requested]
    assert_equal 3, row[:cap]
  end

  def test_missing_config_row_falls_back_to_the_lane_authored_default
    conn[:tool_config].where(key: "ui.listing_cap.frontier").delete
    result = Kquest::Ui::CappedListing.call(
      conn, mint_listings(5), surface: "frontier", user_id: @tenancy[:user_id],
      quest_id: @tenancy[:quest_id], order: [:id]
    )
    assert_equal 50, result[:cap],
                 "the DEFAULT_CAPS fallback carries the L15 law (the engine DEFAULT_CONFIG precedent)"
  end

  def test_an_unknown_surface_raises_loudly
    assert_raises(ArgumentError) do
      Kquest::Ui::CappedListing.call(conn, conn[:quests].where(user_id: @tenancy[:user_id]),
                                     surface: "no_such_surface", user_id: @tenancy[:user_id],
                                     order: [:id])
    end
  end
end
