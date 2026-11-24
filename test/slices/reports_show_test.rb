# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# GET /quests/:quest_id/report — the report view (I16 Part 7): the version
# chain (capped), the citation map, the binding manifest through the LANDED
# ReportBinding machinery, the STALENESS banner (pinned ≠ live), and the arc
# stop markers in synthesis provenance.
class ReportsShowTest < Minitest::Test
  include ActionTestHelper

  LIVE_FP = "b" * 64

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    seed_listing_cap("reports", 50)
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

  def seed_listing_cap(surface, cap)
    key = "ui.listing_cap.#{surface}"
    conn[:tool_config].where(key: key).delete
    conn[:tool_config].insert(key: key, num_value: cap, text_value: nil,
                              provenance: "test data (the seeds re-heal at the next prepare)")
  end

  def mint_version(version_seq: 1, standing: false, pinned_fp: "a" * 64)
    phase_id = conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    kind: "synthesis",
                                    round_no: version_seq)
    session_id = PipelineFixtures.mint_session(conn, user_id: @tenancy[:user_id],
                                               quest_id: @tenancy[:quest_id], phase_id: phase_id)
    vid = conn[:report_versions].insert(
      user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id], version_seq: version_seq,
      synthesis_phase_id: phase_id, created_session_id: session_id, model: "test-model",
      body_blob_key: "reports/#{SecureRandom.uuid}/v#{version_seq}.md",
      body_sha256: "c" * 64, quest_fingerprint: pinned_fp, standing: standing
    )
    Kquest::BlobUploader.store(StringIO.new("# the body v#{version_seq}\n[^1]"),
                               kind: :report, report_version_id: vid)
    vid
  end

  def test_owner_renders_the_report_page_object_with_the_version_chain
    mint_version(version_seq: 1)
    mint_version(version_seq: 2, standing: true)
    status, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/report")
    assert_equal 200, status
    props = parse_json(body)["props"]
    assert_equal "Reports/Show", parse_json(body)["component"]
    assert_equal 2, props["versions"]["rows"].size
    assert_equal 2, props["versions"]["rows"].first["version_seq"], "newest first"
    assert_equal 2, props["standing"]["version_seq"], "the standing version"
    assert_equal "/quests/#{@tenancy[:quest_id]}/report/versions/2/body",
                 props["standing"]["body_url"]
  end

  def test_staleness_banner_fires_only_when_pinned_differs_from_live
    mint_version(version_seq: 1, standing: true, pinned_fp: "a" * 64)
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/report")
    staleness = parse_json(body)["props"]["staleness"]
    assert_equal true, staleness["stale"], "pinned 'a'*64 ≠ live"
    assert_equal "a" * 64, staleness["pinned_fingerprint"]
    assert_match(/\A[0-9a-f]{64}\z/, staleness["live_fingerprint"])

    conn[:report_versions].update(quest_fingerprint: LIVE_FP)
    live = parse_json(inertia_get("/quests/#{@tenancy[:quest_id]}/report")[2])["props"]["staleness"]["live_fingerprint"]
    conn[:report_versions].update(quest_fingerprint: live)
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/report")
    staleness = parse_json(body)["props"]["staleness"]
    assert_equal false, staleness["stale"], "pinned == live: no banner"
  end

  def test_citations_render_by_ordinals
    vid = mint_version(version_seq: 1, standing: true)
    source = OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                              quest_id: @tenancy[:quest_id], snapshot: "z" * 10)
    conn[:report_citations].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                   report_version_id: vid, ordinal: 1, source_id: source[:id])
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/report")
    citations = parse_json(body)["props"]["citations"]
    assert_equal 1, citations.size
    assert_equal 1, citations.first["ordinal"]
    assert_equal source[:id], citations.first["source_id"]
    binding = parse_json(body)["props"]["binding_index"]
    assert binding["citation_index"].any? { |b| b["urn"] == source[:urn] },
           "the binding manifest through the landed ReportBinding machinery"
  ensure
    conn[:report_citations].where(report_version_id: vid).delete if vid
    conn[:quest_sources].where(source_id: source[:id]).delete if source
    conn[:sources].where(id: source[:id]).delete if source
  end

  def test_stop_markers_render_from_synthesis_provenance
    mint_version(version_seq: 1)
    conn[:phases].where(quest_id: @tenancy[:quest_id], kind: "synthesis").update(
      result: Sequel.lit("?::jsonb", JSON.generate(
        stop: {rule_id: "SR-02", phase_no: 3, phase_kind: "descent",
               reason: "web budget exhausted", route: "route-to-synthesis"}
      ))
    )
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/report")
    markers = parse_json(body)["props"]["stop_markers"]
    assert_equal 1, markers.size
    assert_equal "SR-02", markers.first["rule_id"]
    assert_equal "route-to-synthesis", markers.first["route"]
  end

  def test_listings_are_capped_with_telemetry
    seed_listing_cap("reports", 1)
    mint_version(version_seq: 1)
    mint_version(version_seq: 2)
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/report")
    versions = parse_json(body)["props"]["versions"]
    assert_equal 1, versions["rows"].size
    assert_equal 2, versions["requested"]
    assert_equal 1, versions["cap"]
    telemetry = conn[:cap_records].where(user_id: @tenancy[:user_id], surface: "reports")
    assert telemetry.count >= 1
  end

  def test_invisible_quest_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = inertia_get("/quests/#{other[:quest_id]}/report")
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end
end
