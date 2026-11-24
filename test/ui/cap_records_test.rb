# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/orchestrator_fixtures"

# The cap-telemetry ledger (I08 §2.5): one row per capped listing request,
# CHECK-law shape, the overhang rollup, and the CASCADE FKs (matrix-proven:
# plain FKs wedge the landed fixture teardowns — this test proves the
# cleanup path stays clean with telemetry rows present).
class CapRecordsTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    OrchestratorFixtures.sweep_all(conn)
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
  end

  def teardown
    # cap_records rows cascade with their tenancy — the teardown itself
    # exercises the cascade law (a plain FK would raise here).
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def test_record_writes_one_row_with_the_shape_law
    Kquest::Ui::CapRecords.record!(conn, user_id: @tenancy[:user_id],
                                   quest_id: @tenancy[:quest_id], surface: "quest",
                                   requested: 12, cap: 50, existed: 12)
    row = conn[:cap_records].where(user_id: @tenancy[:user_id]).first
    assert_equal 12, row[:requested]
    assert_equal 50, row[:cap]
    assert_equal 12, row[:existed]
    assert_equal "quest", row[:surface]
    refute_nil row[:occurred_at]
  end

  def test_record_accepts_nil_quest_for_cross_quest_listings
    Kquest::Ui::CapRecords.record!(conn, user_id: @tenancy[:user_id], surface: "dashboard",
                                   requested: 3, cap: 50, existed: 3)
    row = conn[:cap_records].first
    assert_nil row[:quest_id]
  end

  def test_check_law_rejects_nonpositive_cap_and_negative_counts
    assert_raises(Sequel::CheckConstraintViolation) do
      Kquest::Ui::CapRecords.record!(conn, user_id: @tenancy[:user_id], surface: "quest",
                                     requested: 1, cap: 0, existed: 1)
    end
    assert_raises(Sequel::CheckConstraintViolation) do
      Kquest::Ui::CapRecords.record!(conn, user_id: @tenancy[:user_id], surface: "quest",
                                     requested: -1, cap: 5, existed: 1)
    end
    assert_raises(Sequel::CheckConstraintViolation) do
      Kquest::Ui::CapRecords.record!(conn, user_id: @tenancy[:user_id], surface: "quest",
                                     requested: 1, cap: 5, existed: -1)
    end
  end

  def test_overhang_by_surface_sums_existed_minus_cap_where_exceeded
    Kquest::Ui::CapRecords.record!(conn, user_id: @tenancy[:user_id], surface: "frontier",
                                   requested: 80, cap: 50, existed: 80)
    Kquest::Ui::CapRecords.record!(conn, user_id: @tenancy[:user_id], surface: "frontier",
                                   requested: 60, cap: 50, existed: 60)
    Kquest::Ui::CapRecords.record!(conn, user_id: @tenancy[:user_id], surface: "quest",
                                   requested: 3, cap: 50, existed: 3)
    rows = Kquest::Ui::CapRecords.overhang_by_surface(conn, user_id: @tenancy[:user_id])
    frontier = rows.find { |r| r[:surface] == "frontier" }
    assert_equal 40, frontier[:overhang], "sum(existed - cap) over the exceeded rows only"
    assert_equal 2, frontier[:capped_requests]
    assert_nil rows.find { |r| r[:surface] == "quest" }, "an unexceeded request carries no overhang"
  end

  def test_overhang_is_tenant_scoped
    other = OrchestratorFixtures.mint_tenancy(conn)
    Kquest::Ui::CapRecords.record!(conn, user_id: other[:user_id], surface: "frontier",
                                   requested: 90, cap: 50, existed: 90)
    assert_empty Kquest::Ui::CapRecords.overhang_by_surface(conn, user_id: @tenancy[:user_id])
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_cascade_keeps_the_landed_fixture_teardown_clean
    Kquest::Ui::CapRecords.record!(conn, user_id: @tenancy[:user_id],
                                   quest_id: @tenancy[:quest_id], surface: "quest",
                                   requested: 80, cap: 50, existed: 80)
    conn[:quests].where(id: @tenancy[:quest_id]).delete
    assert_empty conn[:cap_records].where(quest_id: @tenancy[:quest_id]),
                 "the quest FK cascades — the fixture cleanups never wedge"
  end
end
