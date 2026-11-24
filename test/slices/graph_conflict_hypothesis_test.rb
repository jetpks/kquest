# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /quests/:quest_id/graph/conflicts/:conflict_id/hypothesis —
# HYPOTHESIZE/ADJUDICATE (I17 Part 4 / AC13): set resolution_hypothesis
# (non-empty — the CHECK law) on THIS quest's conflict + the audit row; 422
# on an unknown/foreign conflict or a blank hypothesis; no partial write.
class GraphConflictHypothesisTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    Kquest::Engine::SessionSupervisor.registry_clear
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    sign_in_as_owner
    @claim = PipelineFixtures.mint_claim(conn, user_id: @tenancy[:user_id],
                                         quest_id: @tenancy[:quest_id], seq: 1, text: "a claim")
    @conflict = conn[:conflicts].insert(
      user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id], claim_id: @claim,
      divergence: "the recorded divergence"
    )
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

  def post_hypothesis(overrides = {})
    post("/quests/#{@tenancy[:quest_id]}/graph/conflicts/#{@conflict}/hypothesis",
         params: {hypothesis: "the divergence is a transcription artifact"}.merge(overrides))
  end

  def test_the_hypothesis_is_set_with_the_audit_row
    status, = post_hypothesis
    assert_equal 302, status
    row = conn[:conflicts].where(id: @conflict).first
    assert_equal "the divergence is a transcription artifact", row[:resolution_hypothesis]
    session = Kquest::Ui::OperatorWrite.current_session(conn, quest_id: @tenancy[:quest_id])
    audit = conn[:tool_calls].where(session_id: session[:id], tool: "conflict_hypothesis").first
    refute_nil audit, "the adjudication is audited on the operator session"
    assert_equal true, audit[:ok]
  end

  def test_a_blank_hypothesis_refuses_422_with_no_write
    status, _, body = post_hypothesis(hypothesis: "   ")
    assert_equal 422, status
    assert_match(/non-empty/, Array(body).join)
    assert_nil conn[:conflicts].where(id: @conflict).first[:resolution_hypothesis],
               "no partial write"
  end

  def test_a_foreign_or_unknown_conflict_refuses_422
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "the other quest")
    foreign_claim = PipelineFixtures.mint_claim(conn, user_id: other[:user_id],
                                                quest_id: other[:quest_id], seq: 1, text: "x")
    foreign = conn[:conflicts].insert(user_id: other[:user_id], quest_id: other[:quest_id],
                                      claim_id: foreign_claim, divergence: "d")
    status, _, body = post("/quests/#{@tenancy[:quest_id]}/graph/conflicts/#{foreign}/hypothesis",
                           params: {hypothesis: "h"})
    assert_equal 422, status, "a foreign conflict id never resolves on this quest"
    assert_match(/no such conflict/, Array(body).join)
    status, = post("/quests/#{@tenancy[:quest_id]}/graph/conflicts/#{SecureRandom.uuid}/hypothesis",
                   params: {hypothesis: "h"})
    assert_equal 422, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/graph/conflicts/#{@conflict}/hypothesis",
                   params: {hypothesis: "h"})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = post_hypothesis
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end
end
