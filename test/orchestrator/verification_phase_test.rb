# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/orchestrator/verification_phase"

# The verification machinery (I07 DR-01/DR-02 as runtime behavior): path
# checking (Q1V zero required), the seeded stratified spot-check sample (the
# seed + sampled ids recorded — same graph + same seed = same sample, L14;
# no source contributes more than ⌈n/|S|⌉+1 picks), the conflict-ledger
# review, and the provenance-tier review.
class VerificationPhaseTest < Minitest::Test
  def setup
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    @quest_id = @tenancy[:quest_id]
    # The sample's size row (config data — the cleanup sweep empties the
    # table; the seeds re-heal at the next prepare, the test re-mints).
    conn[:tool_config].where(key: "verification.spot_check_n").delete
    conn[:tool_config].insert(key: "verification.spot_check_n", num_value: 20,
                              provenance: "I07 DR-02 ruling A (test-minted)")
  end

  def teardown
    OrchestratorFixtures.cleanup(conn, user_id: @user_id)
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def phase = @phase ||= conn[:phases].insert(user_id: @user_id, quest_id: @quest_id,
                                              kind: "verification")

  def machinery
    Kquest::Orchestrator::VerificationPhase.new(conn: conn, quest: conn[:quests].where(id: @quest_id).first,
                                                phase: conn[:phases].where(id: phase).first)
  end

  # ── the sampler (pure — the L14 determinism law) ──────────────────────

  def rows_across(sources:, per_source: 6)
    (1..sources).flat_map do |s|
      (1..per_source).map do |i|
        {id: SecureRandom.uuid, source_id: "src-#{s}", span_start: i, span_end: i + 3,
         span_text: "span"}
      end
    end
  end

  def test_same_seed_same_sample
    rows = rows_across(sources: 3)
    band_of = ->(_row) { "mid" }
    picked_a, = Kquest::Orchestrator::VerificationPhase.sample(rows, n: 10, seed: 42,
                                                               band_of: band_of)
    picked_b, = Kquest::Orchestrator::VerificationPhase.sample(rows, n: 10, seed: 42,
                                                               band_of: band_of)

    assert_equal picked_a, picked_b, "same graph + same seed = the same sample (L14)"
    assert_equal 10, picked_a.size
  end

  def test_no_source_contributes_more_than_ceiling_plus_one
    rows = rows_across(sources: 4)
    counts = Hash.new(0)
    picked, = Kquest::Orchestrator::VerificationPhase.sample(
      rows, n: 20, seed: 7, band_of: ->(_r) { "mid" }
    ) do |_row|
      true
    end
    picked.each do |id|
      row = rows.find { |r| r[:id] == id }
      counts[row[:source_id]] += 1
    end
    cap = 20 / 4 + 1 # ⌈n/|S|⌉ + 1 with even division
    counts.each_value do |n|
      assert_operator n, :<=, cap, "no source contributes more than ⌈n/|S|⌉+1 picks"
    end
    assert_equal 20, picked.size
  end

  def test_sample_stratifies_across_need_bands
    rows = (1..24).map do |i|
      {id: SecureRandom.uuid, source_id: "src-#{i % 4}", span_start: 1, span_end: 4,
       span_text: "span", band: i % 3}
    end
    band_of = ->(r) { %w[high mid low][r[:band]] }
    picked, = Kquest::Orchestrator::VerificationPhase.sample(rows, n: 12, seed: 9,
                                                             band_of: band_of)
    bands = picked.map do |id|
      row = rows.find { |r| r[:id] == id }
      band_of.call(row)
    end.uniq
    assert_equal %w[high mid low], bands.sort_by { |b| %w[high mid low].index(b) }.sort,
                 "all present need bands contribute" unless bands.size == 3
    assert_operator bands.size, :>=, 3, "the round-robin reaches every band"
  end

  # ── the live machinery ────────────────────────────────────────────────

  def test_q1v_zero_on_a_clean_graph_and_findings_on_a_dangling_chain
    snapshot = "the fixture corpus text for verification"
    source = OrchestratorFixtures.mint_source(conn, user_id: @user_id, quest_id: @quest_id,
                                              snapshot: snapshot)
    # Evidence 1 (span exact) + its claim; a TERMINAL claim the chain reaches.
    evidence_id = conn[:evidence].insert(user_id: @user_id, quest_id: @quest_id,
                                         source_id: source[:id], source_anchorable: true,
                                         snapshot_char_count: snapshot.length,
                                         span_start: 4, span_end: 22,
                                         span_text: snapshot[4, 18],
                                         reading: "the fixture reading")
    clean_claim = conn[:claims].insert(user_id: @user_id, quest_id: @quest_id, quest_seq: 1,
                                       text: "the clean claim",
                                       urn: "kb:claim:" + Kquest::Pipeline::Base58.encode(
                                         SecureRandom.bytes(12))[0, 10])
    conn[:evidence_edges].insert(user_id: @user_id, quest_id: @quest_id, evidence_id: evidence_id,
                                 relation: "supports", claim_id: clean_claim, position: 1)
    terminal = conn[:claims].insert(user_id: @user_id, quest_id: @quest_id, quest_seq: 2,
                                    text: "the terminal claim", terminal_type: "primary-empirical",
                                    terminal_basis: "the fixture corpus",
                                    urn: "kb:claim:" + Kquest::Pipeline::Base58.encode(
                                      SecureRandom.bytes(12))[0, 10])
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: clean_claim,
                                    parent_claim_id: terminal, position: 1)
    assert_empty machinery.path_check, "the derivation chain reaches a typed terminal (Q1V zero)"

    # A DANGLING leaf: a derivation PARENT with no terminal, no further
    # derivation, and no open frontier entry (the Q1V walk's broken closure).
    dangling_id = conn[:claims].insert(user_id: @user_id, quest_id: @quest_id, quest_seq: 3,
                                       text: "the dangling claim",
                                       urn: "kb:claim:" + Kquest::Pipeline::Base58.encode(
                                         SecureRandom.bytes(12))[0, 10])
    child = conn[:claims].insert(user_id: @user_id, quest_id: @quest_id, quest_seq: 4,
                                 text: "the child of the dangling claim",
                                 urn: "kb:claim:" + Kquest::Pipeline::Base58.encode(
                                   SecureRandom.bytes(12))[0, 10])
    conn[:claim_derivations].insert(user_id: @user_id, quest_id: @quest_id, claim_id: child,
                                    parent_claim_id: dangling_id, position: 1)
    dangling = machinery.path_check
    assert_equal 1, dangling.size, "the dangling leaf is a finding"
    conn[:claim_derivations].where(quest_id: @quest_id, claim_id: child).delete
    conn[:claims].where(quest_id: @quest_id, quest_seq: [3, 4]).delete
  end

  def test_spot_check_finds_span_mismatches_and_records_seed_and_ids
    snapshot = "0123456789 the fixture corpus"
    source = OrchestratorFixtures.mint_source(conn, user_id: @user_id, quest_id: @quest_id,
                                              snapshot: snapshot)
    # One exact span, one MISMATCHED span (quote-mining's measurable half).
    good = conn[:evidence].insert(user_id: @user_id, quest_id: @quest_id, source_id: source[:id],
                                  source_anchorable: true, snapshot_char_count: snapshot.length,
                                  span_start: 14, span_end: 22, span_text: snapshot[14, 8],
                                  reading: "faithful")
    bad = conn[:evidence].insert(user_id: @user_id, quest_id: @quest_id, source_id: source[:id],
                                 source_anchorable: true, snapshot_char_count: snapshot.length,
                                 span_start: 0, span_end: 4, span_text: "LIES",
                                 reading: "unfaithful")
    result = machinery.spot_check

    assert result["seed"], "the seed is recorded"
    assert_includes result["sampled_ids"], good.to_s
    assert_includes result["sampled_ids"], bad.to_s
    findings = result["findings"]
    assert_equal 1, findings.size, "exactly the mismatched span is a finding"
    assert_includes findings.first, bad.to_s
  end

  def test_run_writes_the_full_result_and_clean_when_zero_findings
    snapshot = "clean fixture text for the run"
    source = OrchestratorFixtures.mint_source(conn, user_id: @user_id, quest_id: @quest_id,
                                              snapshot: snapshot)
    conn[:evidence].insert(user_id: @user_id, quest_id: @quest_id, source_id: source[:id],
                           source_anchorable: true, snapshot_char_count: snapshot.length,
                           span_start: 0, span_end: 10, span_text: snapshot[0, 10],
                           reading: "faithful")
    result = machinery.run

    assert result["clean"], "Q1V zero + zero spot findings = clean"
    assert_equal [], result["q1v_dangling"]
    assert_instance_of Hash, result["provenance_review"]
  end

  def test_provenance_review_surfaces_the_corpus_tiers
    OrchestratorFixtures.mint_source(conn, user_id: @user_id, quest_id: @quest_id,
                                     snapshot: "citable fixture text", role: "citable")
    OrchestratorFixtures.mint_source(conn, user_id: @user_id, quest_id: @quest_id,
                                     snapshot: "agenda fixture text", role: "agenda")
    review = machinery.provenance_review

    assert_equal 1, review["citable"]
    assert_equal 1, review["agenda"],
                 "the provenance ≠ truth agenda item is surfaced, never adjudicated"
  end
end
