# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# GET /quests/:quest_id/frontier.csv — the frontier inspector's ONE read-only
# export (I16 Part 5): a capped text/csv snapshot of the mass-ordered listing.
class GraphFrontierExportTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    seed_listing_cap("frontier", 50)
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

  def mint_frontier(need:, uncertainty: 3, relevance: 3, seq: nil)
    claim_id = PipelineFixtures.mint_claim(conn, user_id: @tenancy[:user_id],
                                           quest_id: @tenancy[:quest_id],
                                           seq: seq || (conn[:claims].where(quest_id: @tenancy[:quest_id]).count + 1),
                                           text: "claim #{need}")
    phase_id = conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    kind: "descent",
                                    round_no: conn[:phases].where(quest_id: @tenancy[:quest_id]).count + 1)
    conn[:frontier_entries].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                   claim_id: claim_id, need: need, uncertainty: uncertainty,
                                   relevance: relevance, spawned_by_phase_id: phase_id)
  end

  def test_export_is_csv_with_a_disposition
    mint_frontier(need: "a primary on X", uncertainty: 4, relevance: 5)
    status, headers, body = get("/quests/#{@tenancy[:quest_id]}/frontier.csv")
    assert_equal 200, status
    assert_match "text/csv", headers["content-type"]
    assert_match(/attachment.*frontier-#{@tenancy[:quest_id]}\.csv/, headers["content-disposition"])
    lines = Array(body).join.lines
    assert_equal "entry_id,claim_seq,need,uncertainty,relevance,mass,opened_at\n", lines.first
    assert_match /a primary on X,4,5,20/, lines[1]
  end

  def test_export_is_capped_with_telemetry
    seed_listing_cap("frontier", 1)
    mint_frontier(need: "n1", uncertainty: 5, relevance: 5)
    mint_frontier(need: "n2", uncertainty: 1, relevance: 1, seq: 2)
    status, _, body = get("/quests/#{@tenancy[:quest_id]}/frontier.csv")
    assert_equal 200, status
    lines = Array(body).join.lines
    assert_equal 2, lines.size, "the cap bounds the export (header + 1 row)"
    assert_match "n1", lines[1], "the mass order governs which row the cap keeps"
    telemetry = conn[:cap_records].where(user_id: @tenancy[:user_id], surface: "frontier")
    assert telemetry.count >= 1
  end

  def test_invisible_quest_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = get("/quests/#{other[:quest_id]}/frontier.csv")
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end
end
