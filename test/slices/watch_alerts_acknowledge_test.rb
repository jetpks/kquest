# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /alerts/acknowledge — the ONE write on the alerting surface (I16 Part
# 2): a UI state ONLY — flash/session. It writes NOTHING to PG: no ledger row,
# no telemetry, no view mutation (the map's law: "a UI state, never a system
# state").
class WatchAlertsAcknowledgeTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    # flash_from_redirect GETs "/" — the dashboard's own capped listing needs
    # its cap row (test data; the seeds re-heal at the next prepare).
    conn[:tool_config].where(key: "ui.listing_cap.dashboard").delete
    conn[:tool_config].insert(key: "ui.listing_cap.dashboard", num_value: 50, text_value: nil,
                              provenance: "test data (the seeds re-heal at the next prepare)")
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

  def test_acknowledge_sets_flash_and_session_ui_state
    status, headers, = post("/alerts/acknowledge", params: {predicate: "tw_wedge"})
    assert_equal 302, status
    assert_match %r{/alerts}, headers["location"]
    flash = flash_from_redirect(headers)
    assert_match "Acknowledged tw_wedge", flash["notice"]
    assert_match "a UI state only", flash["notice"]
  end

  def test_acknowledge_writes_nothing_to_pg
    # A full snapshot of the write-able tables before/after — the absence of a
    # DB handle on the action is the LAW; this is the behavioral proof.
    tables = %i[quests quest_lifecycle_events cap_records tool_calls sessions phases
                usage_events claims evidence frontier_entries report_versions]
    before = tables.to_h { |t| [t, conn[t].count] }
    post("/alerts/acknowledge", params: {predicate: "tw_wedge"})
    after = tables.to_h { |t| [t, conn[t].count] }
    assert_equal before, after, "acknowledge is flash/session ONLY — zero PG writes"
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = post("/alerts/acknowledge", params: {predicate: "tw_wedge"})
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end
end
