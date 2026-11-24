# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /quests/:quest_id/console/mute — the alerting mute (I17 Part 6 / AC6):
# the ONE config-ROW write — ONE `tool_config` row per (quest, predicate),
# key `alerts.mute.<quest_id>.<predicate>`, text_value the reason, provenance
# the operator who/why, upsert-shaped; `remove` deletes it;
# tw_hub_divergence is NOT muteable (it routes to adjudication); every
# refusal a teaching 422 with no partial write; no lifecycle row.
class QuestConsoleMuteTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn, state: "paused")
    sign_in_as_owner
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
    conn[:tool_config].where(Sequel.like(:key, "alerts.mute.%")).delete
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  Owner = Struct.new(:id, :github_uid, :username, :name, :email, :avatar_url, keyword_init: true)

  def sign_in_as_owner
    row = conn[:users].where(id: @tenancy[:user_id]).first
    sign_in(Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                      name: row[:name], email: row[:email], avatar_url: row[:avatar_url]))
  end

  def post_mute(params) = post("/quests/#{@tenancy[:quest_id]}/console/mute", params: params)

  def mute_rows
    conn[:tool_config].where(Sequel.like(:key, "alerts.mute.#{@tenancy[:quest_id]}.%")).to_a
  end

  def test_the_mute_writes_one_config_row_with_the_frozen_key_shape
    status, = post_mute(predicate: "tw_churn", reason: "slow local model — expected pace")
    assert_equal 302, status
    rows = mute_rows
    assert_equal 1, rows.size, "ONE tool_config row per (quest, predicate)"
    row = rows.first
    assert_equal "alerts.mute.#{@tenancy[:quest_id]}.tw_churn", row[:key]
    assert_equal "slow local model — expected pace", row[:text_value], "the reason is the why"
    assert_match(/\Aoperator \S+ \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z — slow local model — expected pace\z/,
                 row[:provenance], "the who/why: operator <username> <UTC iso> — <reason>")
    assert_nil row[:num_value], "ck_tool_config_exactly_one: the text side carries the row"
  end

  def test_re_muting_replaces_the_row_upsert_shaped
    post_mute(predicate: "tw_churn", reason: "first")
    post_mute(predicate: "tw_churn", reason: "second — revised")
    rows = mute_rows
    assert_equal 1, rows.size, "re-muting REPLACES the row, never a second one"
    assert_equal "second — revised", rows.first[:text_value]
  end

  def test_remove_deletes_the_row
    post_mute(predicate: "tw_churn", reason: "why")
    status, = post_mute(predicate: "tw_churn", remove: "true")
    assert_equal 302, status
    assert_empty mute_rows, "the filter's removal — the signal's ledger rows were never touched"
  end

  def test_removing_an_absent_row_refuses_teaching
    status, _, body = post_mute(predicate: "tw_churn", remove: "true")
    assert_equal 422, status
    assert_match(/nothing to remove/, Array(body).join)
  end

  def test_tw_hub_divergence_is_not_muteable_it_routes_to_adjudication
    status, _, body = post_mute(predicate: "tw_hub_divergence", reason: "why")
    assert_equal 422, status
    assert_match(/NOT muteable.*adjudication/, Array(body).join)
    assert_empty mute_rows, "no partial write"
  end

  def test_an_unknown_predicate_refuses_teaching
    status, _, body = post_mute(predicate: "tw_bogus", reason: "why")
    assert_equal 422, status
    assert_match(/unknown predicate/, Array(body).join)
  end

  def test_a_blank_reason_refuses_teaching
    status, _, body = post_mute(predicate: "tw_churn", reason: "   ")
    assert_equal 422, status
    assert_match(/a reason is REQUIRED/, Array(body).join)
    assert_empty mute_rows
  end

  def test_no_lifecycle_row_the_mute_is_no_transition
    post_mute(predicate: "tw_churn", reason: "why")
    assert_empty conn[:quest_lifecycle_events],
                 "the mute is a display filter — no transition, no ledger row"
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, state: "paused", topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/console/mute",
                   params: {predicate: "tw_churn", reason: "why"})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = post_mute(predicate: "tw_churn", reason: "why")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end
end
