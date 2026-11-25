# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/engine/provider_desk"

# POST /quests/:quest_id/briefing/turns — the operator chat turn's enqueue
# door (I18 Spec Part 2.2 / AC4 + AC6): owner gate → the open briefing
# session REQUIRED (422 teaching otherwise) → OperatorWrite.enqueue_turn! →
# PRG redirect + flash. THE NO-LLM-IN-WEB ASSERT (the named test): with
# ProviderDesk stubbed to RAISE on construction, the submit still succeeds —
# the web path never constructs provider machinery (BRIEF §3 zero-auto; the
# row IS the turn, the worker executes the agent half).
class QuestBriefingTurnTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    Kquest::Engine::SessionSupervisor.registry_clear
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    sign_in_as_owner
    @session_id = Kquest::Ui::OperatorWrite.open_session!(
      conn, user: {id: @tenancy[:user_id], username: "op"},
      quest: conn[:quests].where(id: @tenancy[:quest_id]).first
    ).fetch(:id)
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

  def post_turn(body = "what is the scope of the decay question?")
    post("/quests/#{@tenancy[:quest_id]}/briefing/turns", params: {body: body})
  end

  def test_submitting_enqueues_the_turn_and_redirects_prg
    status, headers, = post_turn
    assert_equal 302, status, "the PRG redirect"
    assert_equal "/quests/#{@tenancy[:quest_id]}/briefing", headers["location"],
                 "back to the chat page"
    rows = conn[:briefing_turns].where(session_id: @session_id).to_a
    assert_equal 1, rows.size
    assert_equal "enqueued", rows.first[:state]
    assert_equal 1, rows.first[:seq], "the door's per-session seq"
    assert_equal "what is the scope of the decay question?", rows.first[:body]
    assert_nil rows.first[:consumed_at], "the worker stamps consumed_at at consume time"

    status, = post_turn("and the second half?")
    assert_equal 302, status
    assert_equal 2, conn[:briefing_turns].where(session_id: @session_id).max(:seq),
                 "the seq is per-session max+1"
  end

  def test_the_no_llm_in_web_assert_the_turn_enqueues_with_provider_desk_poisoned
    # The named zero-auto assert: ANY provider machinery construction in the
    # web path (ProviderDesk.new) would raise — the enqueue must succeed
    # anyway, proving the action writes ONLY the queue row.
    Kquest::Engine::ProviderDesk.singleton_class.alias_method(:i18cu_original_new, :new)
    Kquest::Engine::ProviderDesk.singleton_class.define_method(:new) do |*|
      raise "NO-LLM-IN-WEB: the web process must never construct provider machinery"
    end
    status, = post_turn
    assert_equal 302, status, "the enqueue succeeds with provider construction poisoned"
    assert_equal 1, conn[:briefing_turns].where(session_id: @session_id).count
  ensure
    Kquest::Engine::ProviderDesk.singleton_class.alias_method(:new, :i18cu_original_new)
    Kquest::Engine::ProviderDesk.singleton_class.remove_method(:i18cu_original_new)
  end

  def test_submitting_requires_the_open_session_422_teaching
    Kquest::Ui::OperatorWrite.end_session!(conn, quest_id: @tenancy[:quest_id])
    status, _, body = post_turn
    assert_equal 422, status
    joined = Array(body).join
    assert_includes joined, "no open briefing session"
    assert_includes joined, "/briefing/session", "the refusal names the open-session door"
    assert_empty conn[:briefing_turns].to_a, "no row behind the refusal"
  end

  def test_a_blank_body_refuses_422_with_no_row
    status, _, body = post_turn("   ")
    assert_equal 422, status
    assert_includes Array(body).join, "empty", "the door's teaching refusal, rendered"
    assert_empty conn[:briefing_turns].to_a
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/briefing/turns", params: {body: "hi"})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = post_turn
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end
end
