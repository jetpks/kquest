# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /quests/:quest_id/graph/conflicts — LEDGER A CONFLICT (I17 Part 4 /
# AC13): ONE transaction — the claim must be THIS quest's; the sources must
# resolve to the operator's OWN citable sources; the conflicts row + the
# conflict_sources exhibit rows (source_anchorable: true) + the
# conflict_ledger audit row; every refusal a teaching 422 with no partial
# write; the hub is never touched.
class GraphConflictsCreateTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    Kquest::Engine::SessionSupervisor.registry_clear
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    sign_in_as_owner
    @claim = PipelineFixtures.mint_claim(conn, user_id: @tenancy[:user_id],
                                         quest_id: @tenancy[:quest_id], seq: 1,
                                         text: "the divergent claim")
    @source = OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                               quest_id: @tenancy[:quest_id],
                                               snapshot: "the exhibit text")
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

  def post_conflict(overrides = {})
    post("/quests/#{@tenancy[:quest_id]}/graph/conflicts", params: {
      claim_id: @claim, divergence: "the type diverges across the corpus",
      source_urns: [@source[:urn]]
    }.merge(overrides))
  end

  def test_the_conflict_rows_and_the_audit_land_in_one_transaction
    status, = post_conflict(hypothesis: "the divergence is a generation artifact")
    assert_equal 302, status
    conflict = conn[:conflicts].where(quest_id: @tenancy[:quest_id]).first
    refute_nil conflict
    assert_equal "the type diverges across the corpus", conflict[:divergence]
    assert_equal "the divergence is a generation artifact", conflict[:resolution_hypothesis]
    exhibits = conn[:conflict_sources].where(conflict_id: conflict[:id]).to_a
    assert_equal 1, exhibits.size
    assert_equal true, exhibits.first[:source_anchorable], "the CHECK law"
    assert_equal @source[:id], exhibits.first[:source_id]
    session = Kquest::Ui::OperatorWrite.current_session(conn, quest_id: @tenancy[:quest_id])
    audit = conn[:tool_calls].where(session_id: session[:id], tool: "conflict_ledger").first
    refute_nil audit, "the tool_calls-shaped audit row"
    assert_equal true, audit[:ok]
  end

  def test_a_foreign_claim_refuses_teaching_with_no_row
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "the other quest")
    foreign = PipelineFixtures.mint_claim(conn, user_id: other[:user_id],
                                          quest_id: other[:quest_id], seq: 1, text: "foreign")
    before = conn[:conflicts].count
    status, _, body = post_conflict(claim_id: foreign)
    assert_equal 422, status
    assert_match(/not this quest's/, Array(body).join)
    assert_equal before, conn[:conflicts].count
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_an_unresolvable_source_urn_refuses_the_whole_write
    before = conn[:conflicts].count
    status, _, body = post_conflict(source_urns: [@source[:urn], "kb:src:nope"])
    assert_equal 422, status
    assert_match(/citable sources/, Array(body).join)
    assert_equal before, conn[:conflicts].count, "no partial docket entry"
    assert_empty conn[:conflict_sources]
  end

  def test_a_blank_divergence_refuses_teaching
    status, _, body = post_conflict(divergence: "   ")
    assert_equal 422, status
    assert_match(/non-empty divergence/, Array(body).join)
    assert_empty conn[:conflicts]
  end

  def test_the_session_opens_on_demand_for_the_audit
    assert_nil Kquest::Ui::OperatorWrite.current_session(conn, quest_id: @tenancy[:quest_id])
    post_conflict
    refute_nil Kquest::Ui::OperatorWrite.current_session(conn, quest_id: @tenancy[:quest_id]),
               "session-bearing: the write rides the operator's session"
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/graph/conflicts",
                   params: {claim_id: @claim, divergence: "d"})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = post_conflict
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end
end
