# frozen_string_literal: true

require_relative "../test_helper"

# The reports slice: report_versions + report_citations over the migrated
# kquest_test, including the version chain's composite FK chain
# (quest → synthesis phase → session → version).
class SlicesReportsTest < Minitest::Test
  def conn
    @conn ||= Kquest::App["db.gateway"].connection
  end

  def slice
    @slice ||= Kquest::App.slices.to_a.find { |s| s.slice_name.to_s == "reports" }
  end

  def rom
    @rom ||= slice["db.rom"]
  end

  def test_slice_boots
    refute_nil slice
  end

  def test_pinned_relations_resolve_and_count
    %w[report_versions report_citations].each do |key|
      count = rom.relations[key].count
      assert count >= 0, "relation #{key} did not resolve"
    end
  end

  def test_report_versions_repo_round_trip
    user_id  = SecureRandom.uuid
    quest_id = SecureRandom.uuid
    conn[:users].insert(
      id: user_id, handle: "gh-reports-test", github_uid: "reports-test-uid",
      username: "reports-test", created_at: Time.now, updated_at: Time.now
    )
    conn[:quests].insert(
      id: quest_id, user_id: user_id, topic: "reports slice round-trip",
      web_call_budget: 1, token_budget: 1, spend_budget_usd: 0
    )
    phase_id = SecureRandom.uuid
    conn[:phases].insert(id: phase_id, user_id: user_id, quest_id: quest_id, kind: "synthesis")
    session_id = SecureRandom.uuid
    conn[:sessions].insert(
      id: session_id, user_id: user_id, quest_id: quest_id, phase_id: phase_id,
      mode: "autonomous", driver: "orchestrator", model: "test-model"
    )
    version_id = SecureRandom.uuid
    conn[:report_versions].insert(
      id: version_id, user_id: user_id, quest_id: quest_id, version_seq: 1,
      synthesis_phase_id: phase_id, created_session_id: session_id,
      model: "test-model", body_blob_key: "reports/#{quest_id}/v1.md",
      body_sha256: "a" * 64, quest_fingerprint: "b" * 64
    )
    found = slice["repos.report_versions_repo"].by_pk(version_id)
    refute_nil found, "ReportVersionsRepo#by_pk did not find the row"
    assert_equal 1, found.version_seq
  ensure
    conn[:report_versions].where(id: version_id).delete
    conn[:sessions].where(id: session_id).delete
    conn[:phases].where(id: phase_id).delete
    conn[:quests].where(id: quest_id).delete
    conn[:users].where(id: user_id).delete
  end
end
