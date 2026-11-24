# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/pipeline_fixtures"
require "open3"
require "rbconfig"

# The ONE live-key smoke's SKIP SEMANTICS, proven keylessly: a key PATH
# override pointing nowhere → exit 0 with the loud skip marker, and NEVER
# the OK marker (a live success is the only thing that can print it).
class LiveSmokeSkipTest < Minitest::Test
  def script = File.expand_path("../../script/live_embed_smoke.rb", __dir__)

  def test_key_path_override_nonexistent_loud_skip_exit_zero
    env = {**ENV, "KQUEST_SMOKE_KEY_PATH" => "/nonexistent/i12-smoke-key-path"}
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, script)

    assert_predicate status, :success?, "skip exits 0 (a keyless machine never fails the gate)\n#{stderr}"
    assert_includes stdout, "LIVE_SMOKE_SKIPPED_NO_KEY"
    refute_includes stdout, "LIVE_SMOKE_OK", "the OK marker is live-success-only"
  end
end
