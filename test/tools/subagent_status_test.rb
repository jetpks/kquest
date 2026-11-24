# frozen_string_literal: true

require_relative "texts_test"
require "kernel/sync"

# subagent_status — poll a run by id; a missing result NEVER implies death.
class SubagentStatusTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/subagent_status.md", __dir__)

  def setup
    mint
    mint_profiles
    @runner = Kquest::Engine::SubagentRunner.new(conn: conn,
                                                 config: Kquest::Engine::DEFAULT_CONFIG)
    @tool = build_tool("subagent_status", runner: @runner)
  end

  def test_running_shape_byte_matched
    run_id = "run/fixture-running"
    @runner.registry[run_id] = Kquest::Engine::SubagentRunner::Run.new(
      run_id: run_id, session_id: @session[:id], profile: "survey",
      band: %w[K1 K199], status: "running", error: nil, started_at: Time.now, ended_at: nil
    )

    produced = Sync { execute_tool(@tool, run: run_id) }
    expected = frozen_answer("subagent_status")
      .sub("run/7c1d profile=survey state=running elapsed=212s",
           "#{run_id} profile=survey state=running elapsed=#{produced[/elapsed=(\d+)s/, 1]}s")
    assert_equal expected, produced
  end

  def test_completed_shape
    run_id = nil
    Sync do
      run_id = @runner.spawn(parent_session: @session, profile: "survey",
                             tools: %w[status mass], runnable: ->(_run) { nil })
    end
    sleep 0.05
    produced = Sync { execute_tool(@tool, run: run_id) }
    assert_match(/state=complete/, produced)
  end

  def test_unknown_run_refusal_byte_matched
    assert_refusal("subagent_status", "unknown-run", slots: {run: "run/9zzz"},
                   planted: ["run/9zzz"]) do
      Sync { execute_tool(@tool, run: "run/9zzz") }
    end
  end
end
