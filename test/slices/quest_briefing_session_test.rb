# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /quests/:quest_id/briefing/session — the briefing session opens
# through the LANDED launch gate (I17 Part 3 / AC11): mode interactive,
# driver operator, the decompose round-1 mint per I01 DR-13; a live holder
# refuses 422 verbatim (FM-16); the operator SEIZING the write gate on an
# active quest is the one-writer law working as designed (the worker's
# autonomous launch is then refused naming the operator holder).
class QuestBriefingSessionTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    Kquest::Engine::SessionSupervisor.registry_clear
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    sign_in_as_owner
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

  def post_open = post("/quests/#{@tenancy[:quest_id]}/briefing/session", params: {})

  def test_opening_mints_the_decompose_round_one_phase_and_the_operator_session
    status, = post_open
    assert_equal 302, status
    sessions = conn[:sessions].where(quest_id: @tenancy[:quest_id]).to_a
    assert_equal 1, sessions.size
    assert_equal "operator", sessions.first[:driver]
    assert_equal "interactive", sessions.first[:mode]
    assert_nil sessions.first[:ended_at], "the session is LIVE"
    phases = conn[:phases].where(quest_id: @tenancy[:quest_id]).to_a
    assert_equal 1, phases.size, "the binding phase row is minted (I01 DR-13)"
    assert_equal "decompose", phases.first[:kind]
    assert_equal [1, 1, "pending"],
                 [phases.first[:round_no], phases.first[:attempt_no], phases.first[:state]]
    assert_equal phases.first[:id], sessions.first[:phase_id]
  end

  def test_reopening_reuses_the_open_session_never_a_second_one
    post_open
    status, = post_open
    assert_equal 302, status
    assert_equal 1, conn[:sessions].where(quest_id: @tenancy[:quest_id]).count
  end

  def test_the_seizure_is_structural_the_workers_launch_is_refused_naming_the_holder
    post_open
    holder = conn[:sessions].where(quest_id: @tenancy[:quest_id]).first
    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Engine::SessionSupervisor.new(conn: conn).launch(
        user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
        phase_id: holder[:phase_id], mode: "autonomous", driver: "orchestrator",
        model: "test-model"
      )
    end
    assert_equal "WriteGuard", error.error_class
    assert_includes error.message, holder[:id].to_s, "the refusal names the OPERATOR holder"
    assert_equal 1, conn[:sessions].where(quest_id: @tenancy[:quest_id]).count,
                 "the worker's launch landed no session"
  end

  def test_a_live_worker_holder_refuses_the_seizure_verbatim
    phase_id = conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    kind: "decompose")
    holder = conn[:sessions].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    phase_id: phase_id, mode: "autonomous",
                                    driver: "orchestrator", model: "test-model")
    Kquest::Engine::SessionSupervisor.registry << holder
    before = conn[:sessions].where(quest_id: @tenancy[:quest_id]).count
    status, _, body = post_open
    assert_equal 422, status
    joined = Array(body).join
    assert_includes joined, "WRITE-GUARD", "the FROZEN refusal, verbatim"
    assert_includes joined, holder.to_s, "naming the holder session"
    assert_includes joined, "orchestrator", "naming the holder driver"
    assert_equal before, conn[:sessions].where(quest_id: @tenancy[:quest_id]).count
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/briefing/session", params: {})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = post_open
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end
end
