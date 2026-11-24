# frozen_string_literal: true

require_relative "../test_helper"

# The seed contract (I11 Part 3 / AC4): the D4 first registration with the
# law values, the para-800 day-one strategy, the 27/19 config rows in file
# order — and the delete+insert idempotency (a second seed run leaves the
# counts unchanged and heals any drift).
class SeedContractTest < Minitest::Test
  def conn
    @conn ||= Kquest::App["db.gateway"].connection
  end

  def load_seeds!
    load File.expand_path("../../config/db/seeds.rb", __dir__)
  end

  def test_bge_m3_registered_with_d4_law_values
    row = conn[:embedding_models]
            .where(id: "92000000-0000-4000-8000-000000000001").first
    refute_nil row, "the D4 first registration is missing"
    assert_equal "bge-m3-1024", row[:slug]
    assert_equal "bge-m3", row[:wire_name]
    assert_equal "openrouter", row[:provider]
    assert_equal "https://openrouter.ai/api/v1/embeddings", row[:endpoint]
    # a credential REFERENCE, never key material
    assert_equal "env:OPENROUTER_API_KEY", row[:api_key_ref]
    assert_equal 1024, row[:dimensions]
    assert_equal "cosine", row[:metric]
    assert_equal 64, row[:batch_max_texts]
    assert_equal 8192, row[:input_max_chars]
    assert_equal "active", row[:status]
    assert_equal "emb_bge_m3_1024", row[:table_name]
  end

  def test_para_800_day_one_chunk_strategy
    row = conn[:chunk_strategies].where(name: "para-800", version: 1).first
    refute_nil row, "the para-800 day-one chunk strategy is missing"
    assert_equal 800, row[:target_chars]
    assert_equal 0, row[:overlap_chars]
    assert_equal true, row[:paragraph_aligned]
  end

  def test_27_transition_rows_in_file_order
    rows = conn[:phase_transitions].order(:ordinal).to_a
    assert_equal 27, rows.size
    rows.each_with_index do |row, i|
      assert_equal i + 1, row[:ordinal], "ordinal is not the file order at row #{i}"
    end
  end

  def test_first_transition_is_the_graph_invalid_stop_row
    row = conn[:phase_transitions].where(ordinal: 1).first
    refute_nil row
    assert_equal "any-phase", row[:from_phase]
    assert_equal "graph_invalid", row[:event]
    assert_equal "stopped", row[:to_phase]
  end

  def test_19_stop_rule_rows
    assert_equal 19, conn[:stop_rules].count
    assert_equal ("SR-01".."SR-19").to_a,
                 conn[:stop_rules].order(:rule_id).select_map(:rule_id)
  end

  # Idempotency/self-healing: the delete+insert seed re-run leaves the
  # counts unchanged (and would heal a drifted value — the seed-contract
  # gate's mutation bites at the next prepare).
  def test_seed_re_run_is_idempotent
    before = {
      transitions: conn[:phase_transitions].count,
      stop_rules:  conn[:stop_rules].count,
      models:      conn[:embedding_models].count,
      para_800:    conn[:chunk_strategies].where(name: "para-800", version: 1).count
    }
    load_seeds!
    after = {
      transitions: conn[:phase_transitions].count,
      stop_rules:  conn[:stop_rules].count,
      models:      conn[:embedding_models].count,
      para_800:    conn[:chunk_strategies].where(name: "para-800", version: 1).count
    }
    assert_equal before, after
  end
end
