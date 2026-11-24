# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# GET /quests/:quest_id/costs.csv — the cost view's ONE export (I16 Part 8):
# the same filtered, CAPPED ledger as text/csv. Reporting-only — the export
# throttles nothing.
class QuestCostsExportTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    seed_listing_cap("costs", 100)
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

  def mint_usage(model: "test-model", round_no: 1)
    phase_id = conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    kind: "descent", round_no: round_no)
    session_id = PipelineFixtures.mint_session(conn, user_id: @tenancy[:user_id],
                                               quest_id: @tenancy[:quest_id], phase_id: phase_id)
    conn[:usage_events].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                               phase_id: phase_id, session_id: session_id, kind: "llm",
                               model: model, input_tokens: 100, output_tokens: 5,
                               cost_usd: BigDecimal("0.25"))
  end

  def test_export_is_csv_with_a_disposition
    mint_usage
    status, headers, body = get("/quests/#{@tenancy[:quest_id]}/costs.csv")
    assert_equal 200, status
    assert_match "text/csv", headers["content-type"]
    assert_match(/attachment/, headers["content-disposition"])
    lines = Array(body).join.lines
    assert_equal "created_at,kind,model,input_tokens,output_tokens,cache_read_tokens," \
                 "cache_write_tokens,cost_usd,phase_id,session_id\n",
                 lines.first, "the frozen export header"
    assert_match(/llm,test-model,100,5/, lines[1])
    assert_match(/0.25/, lines[1])
  end

  def test_export_is_capped_with_telemetry_and_honors_the_model_filter
    seed_listing_cap("costs", 1)
    mint_usage(model: "model-a", round_no: 1)
    mint_usage(model: "model-b", round_no: 2)
    status, _, body = get("/quests/#{@tenancy[:quest_id]}/costs.csv",
                          params: {model: "model-b"})
    assert_equal 200, status
    lines = Array(body).join.lines
    assert_equal 2, lines.size, "the cap bounds the export (header + 1 row)"
    assert_match "model-b", lines[1]
    telemetry = conn[:cap_records].where(user_id: @tenancy[:user_id], surface: "costs")
    assert telemetry.count >= 1, "one telemetry row per capped listing request"
  end

  def test_invisible_quest_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = get("/quests/#{other[:quest_id]}/costs.csv")
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end
end
