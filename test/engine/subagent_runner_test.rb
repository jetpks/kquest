# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/pipeline_fixtures"

# The SubagentRunner — nested restricted-tool loops (I04 §6). FM-20 /
# E-SPAWN / E-RESTRICT / E-WEDGE's subagent deadline land here. All keyless.
class SubagentRunnerTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    @runner = Kquest::Engine::SubagentRunner.new(conn: conn, config: {})
  end

  def teardown
    PipelineFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  def parent_session
    {id: @tenancy[:session_id], user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
     phase_id: @tenancy[:phase_id], driver: "orchestrator", model: "engine-test-model"}
  end

  # FM-20 / E-SPAWN — spawn RETURNS IMMEDIATELY while the child is still
  # streaming; status is a SEPARATE query keyed by run id; a missing result
  # never implies death.
  def test_FM20_spawn_returns_immediately_and_status_is_a_separate_query # E-SPAWN
    child_done = false
    Sync do
      t0 = Time.now
      run_id = @runner.spawn(parent_session: parent_session, profile: "survey",
                             tools: %w[status search list],
                             runnable: ->(_run) { sleep 0.5; child_done = true })
      spawn_seconds = Time.now - t0

      assert_operator spawn_seconds, :<, 0.2, "spawn RETURNS IMMEDIATELY (detached)"
      assert_equal false, child_done, "the child is still streaming when spawn returns"
      refute_equal :unknown, @runner.status(run_id), "a SEPARATE status query keys the run"
      assert_equal "running", @runner.status(run_id).fetch(:status),
                   "a missing result NEVER implies 'no process'"
      assert_equal :unknown, @runner.status(SecureRandom.uuid),
                   "an unknown run id polls (never reads as death)"

      sleep 0.8
      assert_equal "complete", @runner.status(run_id).fetch(:status)
      assert child_done
    end
  end

  # E-RESTRICT — a profile containing `subagent_spawn` is refused AT SPAWN:
  # no recursion.
  def test_E_RESTRICT_spawn_profile_recursion_is_refused
    error = assert_raises(Kquest::Engine::Error) do
      @runner.spawn(parent_session: parent_session, profile: "operator",
                    tools: %w[status subagent_spawn], runnable: ->(_) {})
    end
    assert_match(/E-RESTRICT.*no recursion|no recursion.*E-RESTRICT/m, error.message)

    Sync do
      assert_raises(Kquest::Engine::Error) do
        @runner.spawn(parent_session: parent_session, profile: "operator",
                      tools: %w[status subagent_spawn], runnable: ->(_) {})
      end
    end
  end

  # E-WEDGE — the subagent run deadline: a past-deadline child is terminated
  # and the run marked deadline_exceeded (no unbounded wait exists).
  def test_E_WEDGE_the_subagent_run_deadline_terminates_the_child
    runner = Kquest::Engine::SubagentRunner.new(
      conn: conn,
      config: {"engine.subagent_timeout_s" => {value: 0.3, mode: "advisory"},
               "engine.subagent_status_poll_s" => {value: 30, mode: "advisory"}}
    )
    run_id = nil
    Sync do
      run_id = runner.spawn(parent_session: parent_session, profile: "survey",
                            tools: %w[status], runnable: ->(_run) { sleep 30 })
      sleep 0.6
    end

    assert_equal "deadline_exceeded", runner.status(run_id).fetch(:status)
    assert_match(/E-WEDGE|deadline/, runner.status(run_id).fetch(:error))
  end

  # Child sessions are sessions: their own row (same quest, same phase) so
  # the D10 chain covers child spend (I01 DR-13).
  def test_child_sessions_get_their_own_row_same_quest_and_phase
    run_id = nil
    Sync do
      run_id = @runner.spawn(parent_session: parent_session, profile: "survey",
                             tools: %w[status], runnable: ->(_) {})
    end
    child_session_id = @runner.status(run_id).fetch(:session_id)
    row = conn[:sessions].where(id: child_session_id).first
    refute_nil row
    assert_equal @tenancy[:quest_id], row[:quest_id]
    assert_equal @tenancy[:phase_id], row[:phase_id]
    assert_equal "orchestrator", row[:driver]
  end

  # The band-survey spawn check: pairwise-disjoint bands whose union equals
  # the target range; a gap or overlap is refused loudly.
  def test_band_check_refuses_overlaps_and_gaps
    @runner.check_bands!([1..100, 101..200], range: 1..200) # valid
    assert_raises(Kquest::Engine::Error) { @runner.check_bands!([1..100, 100..200], range: 1..200) }
    assert_raises(Kquest::Engine::Error) { @runner.check_bands!([1..100, 102..200], range: 1..200) }
    assert_raises(Kquest::Engine::Error) { @runner.check_bands!([1..50, 101..200], range: 1..200) }
  end
end
