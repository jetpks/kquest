# frozen_string_literal: true

require_relative "texts_test"
require "kernel/sync"

# subagent_spawn — profile gate + band check + immediate return (the frozen
# answer shape + the verify-with recipe).
class SubagentSpawnTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/subagent_spawn.md", __dir__)

  def setup
    mint
    mint_profiles
    @runner = Kquest::Engine::SubagentRunner.new(conn: conn,
                                                 config: Kquest::Engine::DEFAULT_CONFIG)
    @tool = build_tool("subagent_spawn", runner: @runner)
  end

  def test_spawn_returns_immediately_with_run_id_and_verify_recipe
    answer = Sync do
      execute_tool(@tool, profile: "survey", band: %w[K1 K199], brief: "survey the band")
    end
    run_id = answer[/run=(\S+)/, 1]
    refute_nil run_id
    assert_includes answer, "profile=survey"
    assert_includes answer, "band=K1–K199"
    assert_includes answer, "spawned (detached) — verify with {\"tool\":\"subagent_status\",\"run\":\"#{run_id}\"}"
    assert @runner.status(run_id), "the run id is registered for the separate verification query"
  end

  def test_profile_unknown_refusal_byte_matched
    assert_refusal("subagent_spawn", "profile-unknown",
                   slots: {named: "PROFILE-UNKNOWN: writer"}, planted: ["writer"]) do
      Sync { execute_tool(@tool, profile: "writer", brief: "b") }
    end
  end

  def test_band_overlap_refusal_byte_matched
    # the sibling's band stays RESERVED across the round (any registered run)
    @runner.registry["run/sibling"] = Kquest::Engine::SubagentRunner::Run.new(
      run_id: "run/sibling", session_id: @session[:id], profile: "survey",
      band: %w[K100 K199], status: "running", error: nil, started_at: Time.now, ended_at: nil
    )
    assert_refusal("subagent_spawn", "band-overlap",
                   slots: {overlap: "overlaps K150–K199"}, planted: ["overlaps K150–K199"]) do
      Sync { execute_tool(@tool, profile: "survey", band: %w[K150 K299], brief: "overlapping") }
    end
  end
end
