# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# GET /quests/:quest_id/graph/evidence/:evidence_id/span — the evidence's
# RETURN ADDRESS (I16 Part 6): the pinned snapshot slice at the evidence's
# offsets through the landed BlobUploader reconstitution, byte-pinned against
# sources.snapshot_char_count (a pin mismatch is a loud 422).
class GraphEvidenceSpanTest < Minitest::Test
  include ActionTestHelper

  SNAPSHOT = "The quick brown fox jumps over the lazy dog. " * 3

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    sign_in_as_owner
    @source = OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                               quest_id: @tenancy[:quest_id],
                                               snapshot: SNAPSHOT)
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

  def mint_evidence(span_start: 4, span_end: 20)
    conn[:evidence].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                           source_id: @source[:id], source_anchorable: true,
                           snapshot_char_count: SNAPSHOT.length,
                           span_start: span_start, span_end: span_end,
                           span_text: SNAPSHOT[span_start...span_end],
                           reading: "the fox's color")
  end

  def get_span(evidence_id) = get("/quests/#{@tenancy[:quest_id]}/graph/evidence/#{evidence_id}/span")

  def test_renders_the_pinned_slice_at_the_offsets
    evidence_id = mint_evidence(span_start: 4, span_end: 20)
    status, headers, body = get_span(evidence_id)
    assert_equal 200, status
    assert_match "application/json", headers["content-type"]
    data = parse_json(body)
    assert_equal SNAPSHOT[4...20], data["span_text"]
    assert_equal 4, data["span_start"]
    assert_equal 20, data["span_end"]
    assert_equal "the fox's color", data["reading"]
    assert_equal @source[:urn], data["source_urn"]
    assert_equal true, data["verified"], "byte-pinned against snapshot_char_count"
  end

  def test_pin_mismatch_is_a_loud_422_never_a_shifted_slice
    # The evidence's pin is FK-enforced against the source row, so the
    # mismatch is simulated on the STORE side: a different-length blob lands
    # at the same location — the read refuses loudly instead of slicing a
    # shifted document.
    evidence_id = mint_evidence
    Kquest::BlobUploader.store(StringIO.new("short"), kind: :snapshot,
                               user: @tenancy[:user_id], source_urn: @source[:urn])
    status, _, body = get_span(evidence_id)
    assert_equal 422, status
    assert_match "pin broken", Array(body).join
  end

  def test_absent_evidence_is_404
    status, = get_span(SecureRandom.uuid)
    assert_equal 404, status
  end

  def test_invisible_quest_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    evidence_id = mint_evidence
    status, = get("/quests/#{other[:quest_id]}/graph/evidence/#{evidence_id}/span")
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end
end
