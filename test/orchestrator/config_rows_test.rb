# frozen_string_literal: true

require_relative "../test_helper"

# The I15 config rows (Part 12): the five phase-kind task texts (the phase
# prompt's first part, transcribed from the I06 §9 Task lines with their §
# provenance), `verification.spot_check_n` (I07 DR-02 ruling A) and
# `assurance.poll_interval_s` (I08 §3.4 default) — asserted BY NAME from the
# live seeded rows (the I14 dedup-constants pattern).
class ConfigRowsTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    # The rows are SEED DATA; other suites' cleanup sweeps empty the config
    # tables (the standing law). The seeds' delete+insert shape is idempotent
    # — re-run the seed load here so the rows always mirror the seeds file
    # (the constants are removed first so the reload is silent).
    %w[CALIBRATED_K CALIBRATED_FLOOR ENGINE_CONFIG_DEFAULTS TOOL_CONFIG_DEFAULTS
       PHASE_TASK_TEXTS SURVEY_TOOLS OPERATOR_TOOLS].each do |const|
      Object.send(:remove_const, const) if Object.const_defined?(const)
    end
    load File.expand_path("../../config/db/seeds.rb", __dir__)
  end

  def rows
    @rows ||= conn[:tool_config].to_h { |r| [r.fetch(:key), r] }
  end

  def test_phase_task_text_rows_exist_for_all_five_kinds_with_provenance
    %w[decompose frontier-build descent synthesis verification].each do |kind|
      key = "phase_task_text.#{kind}"
      row = rows[key]
      refute_nil row, "the #{key} row exists (the phase prompt's first part)"
      assert_match(/\S/, row.fetch(:text_value).to_s, "the #{key} row carries its task text")
      assert_includes row.fetch(:provenance), "I06 §9",
                      "the provenance cites the design § the text was transcribed from"
    end
  end

  def test_decompose_task_text_is_transcribed_from_i06_s9_1
    assert_includes rows.fetch("phase_task_text.decompose")[:text_value],
                    "extract verbatim-anchored evidence and claim nodes and seed the frontier"
  end

  def test_descent_task_text_is_transcribed_from_i06_s9_3
    assert_includes rows.fetch("phase_task_text.descent")[:text_value],
                    "resolve its descent need"
  end

  def test_verification_spot_check_n_is_twenty_per_the_dr02_ruling
    row = rows.fetch("verification.spot_check_n")
    assert_equal 20, row.fetch(:num_value).to_i, "I07 DR-02 ruling A: fixed n = 20"
    assert_includes row.fetch(:provenance), "I07 DR-02 ruling A"
  end

  def test_assurance_poll_interval_is_thirty_seconds_per_i08_s3_4
    row = rows.fetch("assurance.poll_interval_s")
    assert_equal 30, row.fetch(:num_value).to_i, "I08 §3.4 default"
    assert_includes row.fetch(:provenance), "I08 §3.4"
  end

  def test_no_engine_config_change_and_no_seeded_provider_rows
    assert_equal 15, conn[:engine_config].count,
                 "the I13 engine config seeds are unchanged (Part 13: no engine_config change)"
    assert_empty conn[:llm_providers].to_a,
                 "no seeded provider rows (tests + scripts upsert their own — the standing law)"
    assert_empty conn[:web_providers].to_a,
                 "no seeded web provider rows (the standing law)"
  end
end
