# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /quests/:quest_id/report/bind — the operator's BIND (I17 Part 5 /
# AC13) through the LANDED report_bind tool: the deterministic binding pass
# over the operator session's draft (citations → ordinals → report_citations
# rows → footnote block → the standing flip INSIDE the tool's own
# transaction, I02 §9); the tool's refusals apply verbatim, audited; the
# no-draft case is a teaching 422 with an audited ok=false row (never a 500).
class ReportsReportBindTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    Kquest::Engine::SessionSupervisor.registry_clear
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id], kind: "synthesis")
    sign_in_as_owner
    @source = OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                               quest_id: @tenancy[:quest_id],
                                               snapshot: "the cited span")
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

  def test_the_binding_pass_flips_standing_inside_the_tools_own_transaction
    post("/quests/#{@tenancy[:quest_id]}/report/draft",
         params: {section: "the question", body: "a claim [^1] anchored in the corpus."})
    status, = post("/quests/#{@tenancy[:quest_id]}/report/bind", params: {})
    assert_equal 302, status
    version = conn[:report_versions].where(quest_id: @tenancy[:quest_id]).first
    assert_equal true, version[:standing], "the standing flip rode the tool's transaction"
    refute_nil version[:bound_at]
    citation = conn[:report_citations].where(report_version_id: version[:id]).first
    refute_nil citation, "the citation index → inline ordinal → report_citations row"
    assert_equal 1, citation[:ordinal]
    assert_equal @source[:id], citation[:source_id]
    assert_equal false, citation[:imported]
    session = Kquest::Ui::OperatorWrite.current_session(conn, quest_id: @tenancy[:quest_id])
    audit = conn[:tool_calls].where(session_id: session[:id], tool: "report_bind").first
    refute_nil audit
    assert_equal true, audit[:ok]
  end

  def test_no_draft_is_a_teaching_422_with_an_audited_ok_false_row
    status, _, body = post("/quests/#{@tenancy[:quest_id]}/report/bind", params: {})
    assert_equal 422, status
    assert_match(/no draft version to bind/, Array(body).join)
    session = Kquest::Ui::OperatorWrite.current_session(conn, quest_id: @tenancy[:quest_id])
    refute_nil session, "the session opened on demand even for the refusal"
    audit = conn[:tool_calls].where(session_id: session[:id], tool: "report_bind", ok: false).first
    refute_nil audit, "the refusal is audited, never a 500"
  end

  def test_the_hash_transcription_refusal_applies_verbatim
    post("/quests/#{@tenancy[:quest_id]}/report/draft",
         params: {section: "the question", body: "a claim citing kb:claim:abc123 directly."})
    status, _, body = post("/quests/#{@tenancy[:quest_id]}/report/bind", params: {})
    assert_equal 422, status
    assert_includes Array(body).join, "REFUSAL", "the tool's hash-transcription law verbatim"
    session = Kquest::Ui::OperatorWrite.current_session(conn, quest_id: @tenancy[:quest_id])
    refusal = conn[:tool_calls].where(session_id: session[:id], tool: "report_bind", ok: false).first
    refute_nil refusal
    assert conn[:report_versions].where(quest_id: @tenancy[:quest_id]).first[:standing].nil? ||
           conn[:report_versions].where(quest_id: @tenancy[:quest_id]).first[:standing] == false,
           "nothing stands behind the refusal"
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/report/bind", params: {})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = post("/quests/#{@tenancy[:quest_id]}/report/bind", params: {})
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end
end
