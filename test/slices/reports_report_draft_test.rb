# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "digest"
require "stringio"

# POST /quests/:quest_id/report/draft — the operator's section draft (I17
# Part 5 / AC13) through the LANDED report_draft tool via OperatorWrite.write!
# — the tool's draft-version law (bound versions frozen — a rework is a NEW
# draft version) and refusals (version-frozen, section-too-large) apply
# verbatim, audited both sides. The operator session binds the quest's
# LATEST phase (a kind-synthesis phase — the report_versions schema law).
class ReportsReportDraftTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    Kquest::Engine::SessionSupervisor.registry_clear
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id], kind: "synthesis")
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

  def post_draft(overrides = {})
    post("/quests/#{@tenancy[:quest_id]}/report/draft", params: {
      section: "the question", body: "the body of the section"
    }.merge(overrides))
  end

  def test_the_section_draft_creates_the_sessions_draft_version
    status, = post_draft
    assert_equal 302, status
    versions = conn[:report_versions].where(quest_id: @tenancy[:quest_id]).to_a
    assert_equal 1, versions.size
    version = versions.first
    assert_equal 1, version[:version_seq]
    assert_nil version[:bound_at], "an unbound draft"
    assert_equal false, version[:standing]
    session = Kquest::Ui::OperatorWrite.current_session(conn, quest_id: @tenancy[:quest_id])
    assert_equal session[:id], version[:created_session_id],
                 "the draft belongs to the operator session"
    audit = conn[:tool_calls].where(session_id: session[:id], tool: "report_draft").first
    refute_nil audit, "audited on the success side too"
    assert_equal true, audit[:ok]
  end

  def test_sections_accumulate_on_the_draft_body_blob
    post_draft
    post_draft(section: "the second section", body: "more body")
    assert_equal 1, conn[:report_versions].where(quest_id: @tenancy[:quest_id]).count,
                 "the same draft accumulates"
  end

  def test_a_bound_versions_frozen_refusal_applies_verbatim_and_is_audited
    session_id = Kquest::Ui::OperatorWrite.open_session!(
      conn, user: {id: @tenancy[:user_id], username: "op"},
      quest: conn[:quests].where(id: @tenancy[:quest_id]).first
    ).fetch(:id)
    fingerprint = conn[:v_quest_graph_fingerprint].where(quest_id: @tenancy[:quest_id])
                                                  .get(:graph_fingerprint) || ("f" * 64)
    conn[:report_versions].insert(
      user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id], version_seq: 7,
      synthesis_phase_id: conn[:sessions].where(id: session_id).first[:phase_id],
      created_session_id: session_id, model: "test-model",
      body_blob_key: "reports/#{SecureRandom.uuid}/v7.md",
      body_sha256: Digest::SHA256.hexdigest("bound"),
      quest_fingerprint: fingerprint, standing: true, bound_at: Time.now,
      binding_pass: "i02-9/i14"
    )
    status, _, body = post_draft(version: "7", section: "s", body: "b")
    assert_equal 422, status
    assert_includes Array(body).join, "REFUSAL", "version-frozen verbatim"
    refusal = conn[:tool_calls].where(session_id: session_id, tool: "report_draft", ok: false).first
    refute_nil refusal, "audited ok=false"
  end

  def test_an_unknown_version_target_is_a_teaching_422_never_a_500
    status, _, body = post_draft(version: "99", section: "s", body: "b")
    assert_equal 422, status
    assert_match(/no version 99/, Array(body).join)
    status, _, body = post_draft(version: "abc", section: "s", body: "b")
    assert_equal 422, status
    assert_match(/version names a version_seq/, Array(body).join)
    assert_empty conn[:tool_calls], "the refusal precedes any tool call"
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/report/draft",
                   params: {section: "s", body: "b"})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = post_draft
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end
end
