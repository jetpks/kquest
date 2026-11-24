# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# POST /quests/:quest_id/briefing/agenda — staging an agenda doc through the
# LANDED FetchBody door (I17 Part 3 / AC11): role `agenda`, idem by content
# address, keyless (the operator supplies url/title/text); requires the open
# briefing session; audited via OperatorWrite.record!; an invalid URL is the
# CHECK law taught, 422 never a 500.
class QuestBriefingAgendaTest < Minitest::Test
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

  def post_stage(overrides = {})
    post("/quests/#{@tenancy[:quest_id]}/briefing/agenda", params: {
      url: "https://example.test/agenda-doc", title: "the agenda doc",
      text: "the agenda document text"
    }.merge(overrides))
  end

  def test_staging_creates_the_agenda_source_and_the_membership_and_the_audit
    status, = post_stage
    assert_equal 302, status
    sources = conn[:sources].where(role: "agenda").to_a
    assert_equal 1, sources.size
    assert_equal "agenda", sources.first[:role]
    membership = conn[:quest_sources].where(quest_id: @tenancy[:quest_id]).to_a
    assert_equal 1, membership.size, "the quest membership registered"
    assert_equal sources.first[:id], membership.first[:source_id]
    audit = conn[:tool_calls].where(session_id: @session_id, tool: "briefing_agenda").first
    refute_nil audit, "the staged row is AUDITED via OperatorWrite.record!"
    assert_equal true, audit[:ok]
    assert_equal @session_id, conn[:sessions].where(id: @session_id).first[:phase_id] &&
                             audit[:session_id]
  end

  def test_re_staging_the_same_bytes_is_content_address_idem
    post_stage
    status, = post_stage
    assert_equal 302, status
    assert_equal 1, conn[:sources].where(role: "agenda").count,
                 "same user + same bytes → the same source (never a second row)"
    assert_equal 1, conn[:quest_sources].where(quest_id: @tenancy[:quest_id]).count,
                 "the repeat registration is a no-op"
  end

  def test_staging_requires_the_open_briefing_session
    conn[:sessions].where(id: @session_id).update(ended_at: Time.now)
    Kquest::Engine::SessionSupervisor.registry_clear
    before = conn[:sources].count
    status, _, body = post_stage
    assert_equal 422, status
    assert_match(/no open briefing session/, Array(body).join)
    assert_equal before, conn[:sources].count, "no partial write behind the refusal"
  end

  def test_an_invalid_url_is_the_check_law_taught_never_a_500
    before = conn[:sources].count
    status, _, body = post_stage(url: "not a url at all")
    assert_equal 422, status
    assert_match(/URL/, Array(body).join)
    assert_equal before, conn[:sources].count
  end

  def test_blank_fields_refuse_teaching
    status, _, body = post_stage(title: "   ")
    assert_equal 422, status
    assert_match(/each required/, Array(body).join)
  end

  def test_non_owner_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = post("/quests/#{other[:quest_id]}/briefing/agenda",
                   params: {url: "https://example.test/x", title: "t", text: "b"})
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = post_stage
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end
end
