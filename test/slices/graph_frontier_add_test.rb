# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /quests/:quest_id/frontier/add — the frontier hand-add (I17 Part 4 /
# AC13): through the LANDED frontier_add tool via OperatorWrite.write! — the
# tool's refusals apply VERBATIM (422 + an audited ok=false row, no entry
# written); the operator session opens on demand; owner-gated.
class GraphFrontierAddTest < Minitest::Test
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
                                         text: "the hand-added claim's target")
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

  def post_add(overrides = {})
    post("/quests/#{@tenancy[:quest_id]}/frontier/add", params: {
      claim: "K1", need: "a primary (authors, year, venue)",
      uncertainty: "4", relevance: "5"
    }.merge(overrides))
  end

  def test_the_hand_add_runs_through_the_landed_tool_with_the_audit
    status, = post_add
    assert_equal 302, status
    entry = conn[:frontier_entries].where(quest_id: @tenancy[:quest_id]).first
    refute_nil entry, "the LANDED tool made the write"
    assert_equal "open", entry[:state]
    session = Kquest::Ui::OperatorWrite.current_session(conn, quest_id: @tenancy[:quest_id])
    refute_nil session, "the operator session opened on demand"
    audit = conn[:tool_calls].where(session_id: session[:id], tool: "frontier_add").first
    refute_nil audit, "the audit rode the same transaction"
    assert_equal true, audit[:ok]
  end

  def test_the_landed_refusals_apply_verbatim_and_are_audited_ok_false
    post_add
    status, _, body = post_add(need: "a different need")
    assert_equal 422, status
    assert_includes Array(body).join, "REFUSAL", "the landed refusal text, verbatim"
    session = Kquest::Ui::OperatorWrite.current_session(conn, quest_id: @tenancy[:quest_id])
    refusal = conn[:tool_calls].where(session_id: session[:id], tool: "frontier_add", ok: false).first
    refute_nil refusal, "the refusal is audited ok=false"
    refute_nil refusal[:error_class], "the census rule-id is the error_class"
    assert_equal 1, conn[:frontier_entries].where(quest_id: @tenancy[:quest_id]).count,
                 "no second entry behind the refusal"
  end

  def test_an_out_of_range_score_is_the_tools_own_teaching
    status, _, body = post_add(uncertainty: "9")
    assert_equal 422, status
    assert_includes Array(body).join, "REFUSAL"
    assert_empty conn[:frontier_entries].where(quest_id: @tenancy[:quest_id])
  end

  def test_an_unknown_node_is_the_tools_own_teaching
    status, _, body = post_add(claim: "K99")
    assert_equal 422, status
    assert_includes Array(body).join, "REFUSAL"
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/frontier/add",
                   params: {claim: "K1", need: "n", uncertainty: "1", relevance: "1"})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = post_add
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_no_process_is_ever_spawned
    Process.stub(:spawn, ->(*_args) { flunk "the UI never spawns — the launcher owns worker boot" }) do
      post_add
    end
  end
end
