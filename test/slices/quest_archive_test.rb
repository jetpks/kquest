# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /quests/:quest_id/archive — the lifecycle door's ARCHIVE half (I16
# Part 1): `complete|stopped → archived` ONLY, carrying the MANDATORY archive
# payload (the counts + graph_fingerprint + verification_phase_id — the
# ck_quest_lifecycle_archive_* CHECKs are the law). Illegal state → 422 with
# NO ledger row and NO state change.
class QuestArchiveTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    sign_in_as_owner
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  Owner = Struct.new(:id, :github_uid, :username, :name, :email, :avatar_url, keyword_init: true)

  def sign_in_as_owner
    row = conn[:users].where(id: @tenancy[:user_id]).first
    user = Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                     name: row[:name], email: row[:email], avatar_url: row[:avatar_url])
    sign_in(user)
    user
  end

  def mint_verification_phase(state: "complete")
    conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                         kind: "verification", state: state)
  end

  def mint_archive_material(claims: 1, evidence: 1, open_frontier: 1)
    claim_id = PipelineFixtures.mint_claim(conn, user_id: @tenancy[:user_id],
                                           quest_id: @tenancy[:quest_id], seq: 1, text: "c")
    (claims - 1).times do |i|
      PipelineFixtures.mint_claim(conn, user_id: @tenancy[:user_id],
                                  quest_id: @tenancy[:quest_id], seq: i + 2, text: "c#{i}")
    end
    source = OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                              quest_id: @tenancy[:quest_id], snapshot: "x" * 10)
    evidence.times do
      conn[:evidence].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                             source_id: source[:id], source_anchorable: true,
                             snapshot_char_count: 10, span_start: 0, span_end: 3,
                             span_text: "xxx", reading: "read")
    end
    phase_id = conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    kind: "descent")
    open_frontier.times do
      conn[:frontier_entries].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                     claim_id: claim_id, need: "need", uncertainty: 3,
                                     relevance: 3, spawned_by_phase_id: phase_id)
    end
  end

  def test_stopped_quest_archives_with_the_mandatory_payload
    mint_verification_phase
    mint_archive_material(claims: 2, evidence: 1, open_frontier: 1)
    conn[:quests].where(id: @tenancy[:quest_id]).update(state: "stopped")

    status, = post("/quests/#{@tenancy[:quest_id]}/archive")
    assert_equal 302, status
    assert_equal "archived", conn[:quests].where(id: @tenancy[:quest_id]).first[:state]

    row = conn[:quest_lifecycle_events].where(to_state: "archived").first
    refute_nil row
    assert_equal "stopped", row[:from_state]
    assert_equal "operator", row[:actor]
    assert_equal 2, row[:claims_at_archive]
    assert_equal 1, row[:evidence_at_archive]
    assert_equal 1, row[:frontier_open_at_archive]
    assert_match(/\A[0-9a-f]{64}\z/, row[:graph_fingerprint], "the fingerprint pin from v_quest_graph_fingerprint")
    refute_nil row[:verification_phase_id], "ck_quest_lifecycle_archive_pair"
    assert_includes row[:note], "ui archive door"
  end

  def test_complete_quest_archives_too
    mint_verification_phase
    conn[:quests].where(id: @tenancy[:quest_id]).update(state: "complete")
    status, = post("/quests/#{@tenancy[:quest_id]}/archive")
    assert_equal 302, status
    assert_equal "archived", conn[:quests].where(id: @tenancy[:quest_id]).first[:state]
    assert_equal "complete", conn[:quest_lifecycle_events].where(to_state: "archived").first[:from_state]
  end

  def test_active_quest_is_422_with_no_ledger_row_and_no_state_change
    mint_verification_phase
    before = conn[:quest_lifecycle_events].count
    status, _, body = post("/quests/#{@tenancy[:quest_id]}/archive")
    assert_equal 422, status
    assert_match "not complete or stopped", Array(body).join
    assert_equal before, conn[:quest_lifecycle_events].count
    assert_equal "active", conn[:quests].where(id: @tenancy[:quest_id]).first[:state]
  end

  def test_archiving_without_a_complete_verification_phase_is_422
    conn[:quests].where(id: @tenancy[:quest_id]).update(state: "stopped")
    before = conn[:quest_lifecycle_events].count
    status, _, body = post("/quests/#{@tenancy[:quest_id]}/archive")
    assert_equal 422, status
    assert_match "no complete verification phase", Array(body).join
    assert_equal before, conn[:quest_lifecycle_events].count
    assert_equal "stopped", conn[:quests].where(id: @tenancy[:quest_id]).first[:state]
  end

  def test_archiving_is_once_only
    mint_verification_phase
    conn[:quests].where(id: @tenancy[:quest_id]).update(state: "stopped")
    post("/quests/#{@tenancy[:quest_id]}/archive")
    before = conn[:quest_lifecycle_events].count
    status, = post("/quests/#{@tenancy[:quest_id]}/archive")
    assert_equal 422, status, "archived is not a legal from_state"
    assert_equal before, conn[:quest_lifecycle_events].count,
                 "uq_quest_lifecycle_archive_once — the ledger row is never duplicated"
  end

  def test_invisible_quest_is_404_before_any_mutation
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    before = conn[:quest_lifecycle_events].count
    status, = post("/quests/#{other[:quest_id]}/archive")
    assert_equal 404, status
    assert_equal before, conn[:quest_lifecycle_events].count
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end
end
