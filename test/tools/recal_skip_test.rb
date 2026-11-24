# frozen_string_literal: true

require_relative "texts_test"

# The recalibration's pinned loud-skip law (I14 Part 6 — the I12 pattern):
# a keyless machine NEVER fails, a keyed machine NEVER silently passes.
class RecalSkipTest < Minitest::Test
  include ToolRig

  SCRIPT = File.expand_path("../../script/dedup_recalibration.rb", __dir__)

  def test_keyless_override_prints_the_loud_skip_and_exits_zero
    out = IO.popen([{"HANAMI_ENV" => "test", "KQUEST_RECAL_KEY_PATH" => "/nonexistent"},
                    RbConfig.ruby, SCRIPT], err: [:child, :out]) { |io| io.read }
    assert_equal 0, $?
    assert_includes out, "RECAL_SKIPPED_NO_KEY"
  end

  def test_the_committed_record_carries_the_machine_greppable_lines
    record = File.read(File.expand_path("../../script/dedup_calibration/record.md", __dir__))
    assert_match(/^floor = \d+\.\d+$/, record)
    assert_match(/^k = \d+$/, record)
    assert_match(/^dataset_sha256 = [0-9a-f]{64}$/, record)
    assert_match(/^pairs = \d+$/, record)
    assert_match(/^model = \S+ [0-9a-f-]{36}$/, record)
    assert_match(/^date = \d{4}-\d{2}-\d{2}T/, record)
  end

  def test_the_dataset_carries_three_families_over_the_frozen_minimums
    lines = File.readlines(File.expand_path("../../script/dedup_calibration/pairs.tsv", __dir__))
    header = lines.shift.chomp.split("\t", -1)
    assert_equal %w[id family text_a text_b provenance], header
    rows = lines.map { |l| l.split("\t", -1) }
    assert_operator rows.size, :>=, 40
    %w[paraphrase same_topic_distinct cross_topic_distinct].each do |fam|
      assert_operator rows.count { |r| r[1] == fam }, :>=, 12, fam
    end
  end
end
