# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/pipeline_fixtures"

# The engine config law (I13 Part 2 / AC4): the three lane-authored tables,
# their CHECKs biting, the 15 frozen `engine_config` keys + the two I05 §8
# `subagent_profiles` rows seeded verbatim, NO seeded `llm_providers` row.
class EngineConfigTest < Minitest::Test
  # The frozen design defaults (I04 §2.5/§7 + DR-09) — asserted BY NAME with
  # the frozen VALUES (config/db/seeds.rb is the landing site).
  FROZEN_KEYS = {
    "engine.transport_retry_cap" => 3,
    "engine.rate_limit_retry_cap" => 5,
    "engine.server_error_retry_cap" => 3,
    "engine.stream_retry_cap" => 2,
    "engine.phase_attempt_cap" => 3,
    "engine.tool_timeout_s" => 120,
    "engine.subagent_timeout_s" => 1800,
    "engine.subagent_status_poll_s" => 30,
    "engine.unknown_tool_alert_at" => 3,
    "engine.dropped_chunk_alert_threshold" => 3,
    "engine.slow_stall_bytes" => 100,
    "engine.slow_stall_window_s" => 1200,
    "engine.unattended_pause_s" => 3600,
    "engine.read_slice_cap_chars" => 8000,
    "engine.embed_retry_cap" => 3
  }.freeze

  SURVEY = %w[status mass node_get neighbors search list paths
              source_read source_grep source_list retrieve].freeze
  OPERATOR = %w[node_add node_set node_get edge_add frontier_add frontier_close
                status search list paths mass neighbors source_read source_grep
                source_list web_search web_fetch retrieve report_draft report_bind
                harness quest_status subagent_spawn subagent_status].freeze

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @user_id = nil
    # the seeds' delete+insert law is SELF-HEALING: the lane's cleanup sweep
    # resets the config tables, so every test re-loads them (mirrors
    # test/db/seed_contract_test.rb's load_seeds!)
    load File.expand_path("../../config/db/seeds.rb", __dir__)
  end

  def teardown
    PipelineFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  def test_the_15_frozen_keys_are_seeded_with_the_frozen_values
    rows = conn[:engine_config].to_a.to_h { |r| [r[:key], Integer(r[:value])] }
    FROZEN_KEYS.each do |key, value|
      assert_equal value, rows[key], "engine_config[#{key}] carries the frozen design default"
    end
    assert_equal FROZEN_KEYS.keys.sort, conn[:engine_config].order(:key).select_map(:key),
                 "no extra keys beyond the frozen 15 (by-name law)"
  end

  def test_all_engine_config_lines_are_advisory_by_default
    modes = conn[:engine_config].to_a.map { |r| [r[:key], r[:mode]] }.to_h
    FROZEN_KEYS.each_key do |key|
      # I05 DR-04 ruling A — read_slice is hard-for-this-line; flipped at I14
      # per the frozen AC9; driver-ruled 79th touch 2026-11-24. Every OTHER
      # line keeps the advisory-by-default assertion (DR-09).
      next if key == "engine.read_slice_cap_chars"

      assert_equal "advisory", modes[key], "DR-09: advisory by default, toggleable to hard"
    end
    assert_equal "hard", modes["engine.read_slice_cap_chars"],
                 "I05 DR-04 ruling A: read_slice ships hard (the ONE amended line)"
    modes.each_value do |mode|
      assert %w[advisory hard].include?(mode)
    end
  end

  def profile_tools(name)
    row = conn[:subagent_profiles].where(name: name).first
    return nil unless row

    tools = row[:tools] # pg_json deserializes; a String on a bare connection
    tools.is_a?(String) ? JSON.parse(tools) : tools
  end

  def test_the_two_day_one_profiles_are_seeded_verbatim
    assert_equal SURVEY, profile_tools("survey"), "I05 §8's survey list verbatim (read-only)"
    assert_equal OPERATOR, profile_tools("operator"), "I05 §8's operator = the FULL surface"
    assert_equal 24, profile_tools("operator").size
  end

  def test_no_llm_providers_row_is_seeded
    assert_equal 0, conn[:llm_providers].count,
                 "provider rows are operator/session-minted config (the day-one ruling); " \
                 "the bge-m3 embedding REGISTRY row is a different table and stays pristine"
  end

  # AC4's negative probes — the CHECKs BITE.
  def test_the_schema_checks_bite
    assert_raises(Sequel::CheckConstraintViolation) do
      conn[:engine_config].insert(key: "probe", value: 1, mode: "bogus", provenance: "probe")
    end
    assert_raises(Sequel::CheckConstraintViolation) do
      conn[:llm_providers].insert(name: "", base_url: "http://x", model_id: "m",
                                  reasoning: true, context_window: 1)
    end
    assert_raises(Sequel::CheckConstraintViolation) do
      conn[:llm_providers].insert(name: "p", base_url: "http://x", model_id: "m",
                                  reasoning: true, context_window: 1, api_key_ref: "file:/nope")
    end
    assert_raises(Sequel::CheckConstraintViolation) do
      conn[:llm_providers].insert(name: "p", base_url: "http://x", model_id: "m",
                                  reasoning: true, context_window: 0)
    end
  end

  # The api_key_ref reference-form LAW holds at the schema (NULL or env:-shaped).
  def test_api_key_ref_reference_form_law
    row = conn[:llm_providers].insert(name: "ref-law-probe", base_url: "http://x", model_id: "m",
                                      reasoning: true, context_window: 1, api_key_ref: nil)
    refute_nil row
    count = conn[:llm_providers].where(Sequel.~(api_key_ref: nil))
                                .where(Sequel.lit("api_key_ref !~ '^env:[A-Za-z_][A-Za-z0-9_]*$'")).count
    assert_equal 0, count
  ensure
    conn[:llm_providers].where(name: "ref-law-probe").delete
  end

  # The engine config reader: DB rows win over the frozen defaults; numeric
  # values normalize to Integers.
  def test_the_config_reader_merges_db_rows_over_the_frozen_defaults
    defaults = Kquest::Engine::DEFAULT_CONFIG.transform_values { |v| {value: v, mode: "advisory"} }
    assert_equal 120, Kquest::Engine.config_value(defaults, "engine.tool_timeout_s")

    @user_id = PipelineFixtures.mint_tenancy(conn)[:user_id]
    conn[:engine_config].where(key: "engine.tool_timeout_s").delete
    conn[:engine_config].insert(key: "engine.tool_timeout_s", value: 0.25, mode: "hard",
                                provenance: "test override")
    lines = Kquest::Engine.config(conn)
    assert_equal 0.25, Kquest::Engine.config_value(lines, "engine.tool_timeout_s")
    assert_equal "hard", lines.fetch("engine.tool_timeout_s").fetch(:mode)
  ensure
    conn[:engine_config].where(key: "engine.tool_timeout_s").delete
  end
end
