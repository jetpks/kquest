# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/orchestrator/ladder"

# The ladder rung harness (I07 §7; I08 §10): the rungs run the REAL engine +
# REAL tools over the in-process mock wires (the mock IS the wire — the
# machinery proof), the PASS record seeds `ladder_passes`, and the live leg
# LOUD-SKIPS keyless (never a silent pass, never fabricated numbers).
class LadderTest < Minitest::Test
  def setup
    @conn = Kquest::App["db.gateway"].connection
    @ladder = Kquest::Orchestrator::Ladder.new(conn: @conn, passed_by: "ladder-test")
  end

  def teardown
    @ladder.mocks.each(&:stop)
    @ladder.evidence.each_key do |session_id|
      @conn[:sessions].where(id: session_id).delete
    end
    # The rung's tenancy (the rig's own cleanup runs on success; a failure
    # path may leave rows — sweep by the fixture user's name).
    user = @conn[:users].where(name: "Ladder Fixture").first
    OrchestratorFixtures.cleanup(@conn, user_id: user[:id]) if user
    @conn[:ladder_passes].delete
  end

  def test_probe_rung_passes_and_seeds_ladder_passes
    Sync do
      evidence_ref = @ladder.probe

      assert_match(/rung=probe session=/, evidence_ref)
      row = @conn[:ladder_passes].where(rung: "probe").first
      refute_nil row, "the PASS record seeds ladder_passes (the landed DDL)"
      assert_equal "ladder-model", row[:model]
      assert_equal "in-process mock wires", row[:serving_stack]
      assert_equal "ladder-test", row[:passed_by]
      assert_includes row[:evidence_ref], "transcript_bytes="
    end
  end

  def test_smoke_rung_mines_every_staged_source_and_passes
    Sync do
      evidence_ref = @ladder.smoke

      assert_match(/rung=smoke/, evidence_ref)
      assert_equal 1, @conn[:ladder_passes].where(rung: "smoke").count
    end
  end

  def test_partial_rung_holds_the_three_zeros_and_the_metabolism_band
    Sync do
      evidence_ref = @ladder.partial

      assert_match(/rung=partial/, evidence_ref)
      assert_equal 1, @conn[:ladder_passes].where(rung: "partial").count
    end
  end

  def test_the_live_leg_loud_skips_keyless
    assert Kquest::Orchestrator::Ladder.live_key_missing?(nil)
    assert Kquest::Orchestrator::Ladder.live_key_missing?("")
    assert Kquest::Orchestrator::Ladder.live_key_missing?("/nonexistent/key/path")
    refute Kquest::Orchestrator::Ladder.live_key_missing?(File.expand_path("../test_helper.rb", __dir__))
  end

  def test_gate_failure_is_loud_never_a_silent_pass
    ladder = Kquest::Orchestrator::Ladder.new(conn: @conn, passed_by: "ladder-test")
    error = assert_raises(Kquest::Orchestrator::Ladder::GateFailure) do
      # A probe gate against an EMPTY quest: no tool call, no artifact — the
      # gate fails loudly (never a fabricated pass).
      ladder.gate_probe!(SecureRandom.uuid)
    end
    assert_match(/no usable first tool call/, error.message)
  end
end
