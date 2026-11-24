# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "digest"

# POST /quests/:quest_id/report/versions/:version_seq/citations/:ordinal/
# import — the EXPLICIT import mark (I17 Part 5 / AC13; BRIEF D3: "explicitly
# marked imports — never silently"): the import-shaped report_citations row
# (imported: true, imported_source_id, import_source_quest_id — the
# ck_report_citations_import_pair law), the source fetch-time-validated to
# the operator's OWN citable sources, the origin quest the SAME user's; the
# XOR law taught (in-corpus XOR import — one row per (version, ordinal)); the
# audit row rides the operator session.
class ReportsReportImportMarkTest < Minitest::Test
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
    @version = mint_version(1)
    @source = OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                               quest_id: @tenancy[:quest_id],
                                               snapshot: "an out-of-corpus citable doc")
    @origin_quest = OrchestratorFixtures.mint_quest(conn, user_id: @tenancy[:user_id])
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

  def mint_version(seq)
    id = SecureRandom.uuid
    conn[:report_versions].insert(
      id: id, user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id], version_seq: seq,
      synthesis_phase_id: @phase_id, created_session_id: @session_id, model: "test-model",
      body_blob_key: "reports/#{id}/v#{seq}.md", body_sha256: Digest::SHA256.hexdigest("v"),
      quest_fingerprint: "a" * 64, standing: false
    )
    id
  end

  def post_import(overrides = {})
    post("/quests/#{@tenancy[:quest_id]}/report/versions/1/citations/5/import", params: {
      source_urn: @source[:urn], origin_quest_id: @origin_quest
    }.merge(overrides))
  end

  def test_the_import_shaped_citation_row_lands_with_the_audit
    status, = post_import
    assert_equal 302, status
    row = conn[:report_citations].where(report_version_id: @version, ordinal: 5).first
    refute_nil row
    assert_equal true, row[:imported], "the import shape"
    assert_equal @source[:id], row[:imported_source_id]
    assert_equal @origin_quest, row[:import_source_quest_id]
    assert_nil row[:source_id], "the XOR law: in-corpus XOR import"
    audit = conn[:tool_calls].where(session_id: @session_id, tool: "report_import_mark").first
    refute_nil audit
    assert_equal true, audit[:ok]
  end

  def test_an_already_bound_ordinal_refuses_the_xor_law_teaching
    conn[:report_citations].insert(
      user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
      report_version_id: @version, ordinal: 5, source_id: @source[:id]
    )
    status, _, body = post_import
    assert_equal 422, status
    assert_match(/already bound/, Array(body).join)
    assert_match(/in-corpus/, Array(body).join)
    assert_equal 1, conn[:report_citations].where(report_version_id: @version).count,
                 "no second row behind the refusal (uq_report_citations_ordinal)"
  end

  def test_a_foreign_source_urn_refuses_teaching
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "another's corpus")
    foreign = OrchestratorFixtures.mint_source(conn, user_id: other[:user_id],
                                               quest_id: other[:quest_id], snapshot: "foreign text")
    status, _, body = post_import(source_urn: foreign[:urn])
    assert_equal 422, status
    assert_match(/YOUR OWN citable source/, Array(body).join)
    assert_empty conn[:report_citations]
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_a_foreign_origin_quest_refuses_the_same_user_day_one_posture
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, _, body = post_import(origin_quest_id: other[:quest_id])
    assert_equal 422, status
    assert_match(/origin quest must be YOURS/, Array(body).join)
    assert_empty conn[:report_citations]
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_an_unknown_version_refuses_422
    status, _, body = post("/quests/#{@tenancy[:quest_id]}/report/versions/9/citations/5/import",
                           params: {source_urn: @source[:urn], origin_quest_id: @origin_quest})
    assert_equal 422, status
    assert_match(/no version 9/, Array(body).join)
  end

  def test_a_missing_explicit_pair_refuses_teaching
    status, _, body = post("/quests/#{@tenancy[:quest_id]}/report/versions/1/citations/5/import",
                           params: {})
    assert_equal 422, status
    assert_match(/EXPLICIT/, Array(body).join)
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/report/versions/1/citations/5/import",
                   params: {source_urn: @source[:urn], origin_quest_id: @origin_quest})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = post_import
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end
end
