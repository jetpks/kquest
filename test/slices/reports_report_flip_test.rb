# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "digest"

# POST /quests/:quest_id/report/versions/:version_seq/flip — the STANDING
# FLIP (I17 Part 5; I02 §7's ENTRY 5 transaction): the target must be THIS
# quest's AND bound (a draft cannot stand); clear the current standing row,
# set the target's standing (the partial-unique one-pointer law); audited
# via the report_flip tool_calls-shaped row (the old→new pair recorded).
class ReportsReportFlipTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    Kquest::Engine::SessionSupervisor.registry_clear
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id], kind: "synthesis")
    sign_in_as_owner
    @phase_id = conn[:phases].where(quest_id: @tenancy[:quest_id], kind: "synthesis").first[:id]
    @session_id = Kquest::Ui::OperatorWrite.open_session!(
      conn, user: {id: @tenancy[:user_id], username: "op"},
      quest: conn[:quests].where(id: @tenancy[:quest_id]).first
    ).fetch(:id)
    @standing = mint_version(1, standing: true, bound: true)
    @challenger = mint_version(2, standing: false, bound: true)
    @draft = mint_version(3, standing: false, bound: false)
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    Kquest::Engine::SessionSupervisor.registry_clear
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  Owner = Struct.new(:id, :github_uid, :username, :name, :email, :avatar_url, keyword_init: true)

  def sign_in_as_owner
    row = conn[:users].where(id: @tenancy[:user_id]).first
    sign_in(Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                      name: row[:name], email: row[:email], avatar_url: row[:avatar_url]))
  end

  def mint_version(seq, standing:, bound:)
    id = SecureRandom.uuid
    conn[:report_versions].insert(
      id: id, user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id], version_seq: seq,
      synthesis_phase_id: @phase_id, created_session_id: @session_id, model: "test-model",
      body_blob_key: "reports/#{id}/v#{seq}.md",
      body_sha256: Digest::SHA256.hexdigest("v#{seq}"),
      quest_fingerprint: "a" * 64, standing: standing,
      bound_at: bound ? Time.now : nil,
      binding_pass: bound ? "i02-9/i14" : nil
    )
    id
  end

  def post_flip(seq) = post("/quests/#{@tenancy[:quest_id]}/report/versions/#{seq}/flip", params: {})

  def test_the_flip_clears_the_old_and_stands_the_new_in_one_transaction
    status, = post_flip(2)
    assert_equal 302, status
    refute conn[:report_versions].where(id: @standing).first[:standing], "the old cleared"
    assert conn[:report_versions].where(id: @challenger).first[:standing], "the new stands"
    audit = conn[:tool_calls].where(session_id: @session_id, tool: "report_flip").first
    refute_nil audit, "the tool_calls-shaped audit row"
    result = JSON.parse(audit[:result].is_a?(String) ? audit[:result] : audit[:result].to_json)
    assert_includes result["content"], "v1 → v2", "the old→new pair recorded"
  end

  def test_a_draft_cannot_stand
    before = conn[:report_versions].where(quest_id: @tenancy[:quest_id], standing: true)
                                   .select_map(:id)
    status, _, body = post_flip(3)
    assert_equal 422, status
    assert_match(/a draft cannot stand/, Array(body).join)
    assert_equal before, conn[:report_versions].where(quest_id: @tenancy[:quest_id],
                                                      standing: true).select_map(:id),
                 "no partial write"
  end

  def test_the_standing_version_refuses_nothing_to_flip
    status, _, body = post_flip(1)
    assert_equal 422, status
    assert_match(/already stands/, Array(body).join)
  end

  def test_an_unknown_version_refuses_422
    status, _, body = post_flip(99)
    assert_equal 422, status
    assert_match(/no version 99/, Array(body).join)
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/report/versions/2/flip", params: {})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = post_flip(2)
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end
end
