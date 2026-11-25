# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/orchestrator_fixtures"

# The ONE shared visibility gate (I08 §4): the I02 frozen M4 per-viewer
# predicate (F6 closure, I20) — the owner sees their quest; a non-owner sees
# it iff one of its sources carries a grant row (owner-attributed) that is
# public OR granted to the viewer OR granted to a workspace the viewer is a
# member of; invisible = false (actions 404 — existence never leaks).
class VisibilityTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    OrchestratorFixtures.sweep_all(conn)
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
  end

  def teardown
    # The I02 tables are the tests' own sweep (reverse-FK: grants → members →
    # workspaces; sweep_all does not know them).
    conn[:resource_grants].where(owner_user_id: [@tenancy[:user_id], @other[:user_id]]).delete
    conn[:workspace_members].where(user_id: [@tenancy[:user_id], @other[:user_id]]).delete
    conn[:workspaces].where(created_by_user_id: [@tenancy[:user_id], @other[:user_id]]).delete
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

  # THE FLIPPED LANDED TEST (F6's ruling trail, I20 Grounds §2.4): the M4
  # alignment is EXECUTED recorded law — I02's frozen M4 → I16 §5's recorded
  # full-alignment promise ("stands until grants are administrable") → I19
  # made grants administrable and recorded F6 as ENTRY 3's → the plan's ENTRY
  # 3 assignment. The landed day-one test
  # (test_workspace_scoped_grant_without_public_does_not_open_the_quest,
  # provisional by its own "F6 day-one semantics" message) flips to its M4
  # truth: a USER-scope grant TO THE VIEWER opens the quest.
  def test_user_scoped_grant_to_the_viewer_opens_the_quest
    source = OrchestratorFixtures.mint_source(conn, user_id: @other[:user_id],
                                              quest_id: @other[:quest_id],
                                              snapshot: "workspace text")
    conn[:resource_grants].insert(source_id: source[:id], owner_user_id: @other[:user_id],
                                  grantee_user_id: @tenancy[:user_id])
    assert Kquest::Ui::Visibility.visible_quest?(conn, user_id: @tenancy[:user_id],
                                                      quest_id: @other[:quest_id]),
           "the M4 per-viewer law: a grant row naming THIS viewer opens the quest"
  end

  # The M4 workspace leg, both sides: a grant to a workspace the viewer is a
  # member of opens the quest; the same grant gives NOTHING to a non-member
  # (the aggregated effective_scope cannot express this — the recorded I15
  # rationale for the day-one approximation, closed here).
  def test_workspace_grant_to_a_members_workspace_opens_the_quest
    outsider = nil
    ws = conn[:workspaces].insert(name: "f6-leg-#{SecureRandom.hex(4)}",
                                  created_by_user_id: @tenancy[:user_id])
    conn[:workspace_members].insert(workspace_id: ws, user_id: @tenancy[:user_id])
    source = OrchestratorFixtures.mint_source(conn, user_id: @other[:user_id],
                                              quest_id: @other[:quest_id],
                                              snapshot: "members-only text")
    conn[:resource_grants].insert(source_id: source[:id], owner_user_id: @other[:user_id],
                                  grantee_workspace_id: ws)
    assert Kquest::Ui::Visibility.visible_quest?(conn, user_id: @tenancy[:user_id],
                                                      quest_id: @other[:quest_id]),
           "membership in the granted workspace opens the quest"

    outsider = OrchestratorFixtures.mint_tenancy(conn, topic: "no membership")
    refute Kquest::Ui::Visibility.visible_quest?(conn, user_id: outsider[:user_id],
                                                      quest_id: @other[:quest_id]),
           "the workspace grant gives a non-member nothing (404-shaped invisibility)"
  end
end
