# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/orchestrator_fixtures"

# The ONE shared visibility gate (I08 §4): owner-or-public over
# `v_resource_visibility` — the landed quest-stream gate's own day-one
# semantics (F6). Both sides per law: the owner sees their quest; anyone else
# only when one of the quest's sources is PUBLIC-scope; invisible = false
# (actions 404 — existence never leaks).
class VisibilityTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    OrchestratorFixtures.sweep_all(conn)
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
  end

  def teardown
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
    OrchestratorFixtures.cleanup(conn, user_id: @other[:user_id])
  end

  def test_owner_sees_their_quest
    assert Kquest::Ui::Visibility.visible_quest?(
      conn, user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id]
    )
  end

  def test_absent_quest_is_not_visible
    refute Kquest::Ui::Visibility.visible_quest?(
      conn, user_id: @tenancy[:user_id], quest_id: SecureRandom.uuid
    )
  end

  def test_other_users_quest_is_invisible_without_a_public_source
    refute Kquest::Ui::Visibility.visible_quest?(
      conn, user_id: @tenancy[:user_id], quest_id: @other[:quest_id]
    )
  end

  def test_public_grant_on_one_of_the_sources_opens_the_quest
    source = OrchestratorFixtures.mint_source(conn, user_id: @other[:user_id],
                                              quest_id: @other[:quest_id],
                                              snapshot: "public text")
    conn[:resource_grants].insert(source_id: source[:id], owner_user_id: @other[:user_id],
                                  is_public: true)
    assert Kquest::Ui::Visibility.visible_quest?(
      conn, user_id: @tenancy[:user_id], quest_id: @other[:quest_id]
    )
  ensure
    conn[:resource_grants].where(source_id: source[:id]).delete if source
    conn[:quest_sources].where(source_id: source[:id]).delete if source
    conn[:sources].where(id: source[:id]).delete if source
  end

  def test_workspace_scoped_grant_without_public_does_not_open_the_quest
    source = OrchestratorFixtures.mint_source(conn, user_id: @other[:user_id],
                                              quest_id: @other[:quest_id],
                                              snapshot: "workspace text")
    conn[:resource_grants].insert(source_id: source[:id], owner_user_id: @other[:user_id],
                                  grantee_user_id: @tenancy[:user_id])
    refute Kquest::Ui::Visibility.visible_quest?(
      conn, user_id: @tenancy[:user_id], quest_id: @other[:quest_id]
    ), "F6 day-one semantics: the aggregated scope cannot attribute per-user grants"
  ensure
    conn[:resource_grants].where(source_id: source[:id]).delete if source
    conn[:quest_sources].where(source_id: source[:id]).delete if source
    conn[:sources].where(id: source[:id]).delete if source
  end
end
