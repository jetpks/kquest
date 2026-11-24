# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# GET /quests/:quest_id/report/versions/:version_seq/body — the ONE read-only
# report action (I16 Part 7): the body blob streamed as an attachment THROUGH
# THE UPLOADER SEAM (location_for(:report, report_version_id:) is the store
# address; body_blob_key is CHECK-law bookkeeping only).
class ReportsBodyTest < Minitest::Test
  include ActionTestHelper

  BODY = "# the body\n\n[^1] the citation\n"

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

  def mint_version(version_seq: 1)
    phase_id = conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    kind: "synthesis", round_no: version_seq)
    session_id = PipelineFixtures.mint_session(conn, user_id: @tenancy[:user_id],
                                               quest_id: @tenancy[:quest_id], phase_id: phase_id)
    vid = conn[:report_versions].insert(
      user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id], version_seq: version_seq,
      synthesis_phase_id: phase_id, created_session_id: session_id, model: "test-model",
      body_blob_key: "reports/#{vid_placeholder(version_seq)}/v#{version_seq}.md",
      body_sha256: "c" * 64, quest_fingerprint: "a" * 64, standing: version_seq == 1
    )
    # The STORE address is the uploader's, not the CHECK-law bookkeeping column:
    # the row's body_blob_key mirrors the layout but the READ goes through
    # location_for(:report, report_version_id:).
    Kquest::BlobUploader.store(StringIO.new(BODY), kind: :report, report_version_id: vid)
    vid
  end

  def vid_placeholder(version_seq) = "00000000-0000-4000-8000-#{format('%012d', version_seq)}"

  def test_body_streams_from_the_uploader_seam_as_an_attachment
    mint_version(version_seq: 3)
    status, headers, body = get("/quests/#{@tenancy[:quest_id]}/report/versions/3/body")
    assert_equal 200, status
    assert_match "text/markdown", headers["content-type"]
    assert_match(/attachment.*report-#{@tenancy[:quest_id]}-v3\.md/, headers["content-disposition"])
    assert_equal BODY, Array(body).join
  end

  def test_absent_version_is_404
    status, = get("/quests/#{@tenancy[:quest_id]}/report/versions/9/body")
    assert_equal 404, status
  end

  def test_non_numeric_version_seq_is_404
    status, = get("/quests/#{@tenancy[:quest_id]}/report/versions/abc/body")
    assert_equal 404, status
  end

  def test_invisible_quest_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = get("/quests/#{other[:quest_id]}/report/versions/1/body")
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end
end
