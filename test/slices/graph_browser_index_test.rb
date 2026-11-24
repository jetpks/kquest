# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# GET /quests/:quest_id/graph — the graph browser (I16 Part 6): the capped
# node lists, closure per claim, lineage, the cross-quest HUB tab, the
# conflicts docket read-only, and the ?node= traversal through the CANONICAL
# query services (Neighborhood#hood / DerivationPaths#paths — never
# re-derived). All writes are I17's.
class GraphBrowserIndexTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    seed_listing_cap("graph", 50)
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

  def mint_graph
    claim_id = PipelineFixtures.mint_claim(conn, user_id: @tenancy[:user_id],
                                           quest_id: @tenancy[:quest_id], seq: 1,
                                           text: "the root claim")
    parent_id = PipelineFixtures.mint_claim(conn, user_id: @tenancy[:user_id],
                                            quest_id: @tenancy[:quest_id], seq: 2,
                                            text: "the parent claim")
    conn[:claims].where(id: parent_id).update(terminal_type: "primary-empirical",
                                              terminal_basis: "the basis")
    conn[:claim_derivations].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    claim_id: claim_id, parent_claim_id: parent_id, position: 1)
    source = OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                              quest_id: @tenancy[:quest_id], snapshot: "x" * 10)
    evidence_id = conn[:evidence].insert(
      user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id], source_id: source[:id],
      source_anchorable: true, snapshot_char_count: 10, span_start: 0, span_end: 3,
      span_text: "xxx", reading: "the reading"
    )
    conn[:evidence_edges].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                 evidence_id: evidence_id, relation: "supports",
                                 claim_id: claim_id, position: 1)
    {claim_id: claim_id, parent_id: parent_id, evidence_id: evidence_id, source: source}
  end

  def test_owner_renders_the_browser_page_object_with_the_capped_lists
    mint_graph
    status, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/graph")
    assert_equal 200, status
    props = parse_json(body)["props"]
    assert_equal "Graph/Browser", parse_json(body)["component"]
    assert_equal 2, props["claims"]["rows"].size, "the claims list (capped)"
    assert_equal 1, props["evidence"]["rows"].size
    assert_equal 1, props["edges"]["rows"].size
    assert_equal 1, props["derivations"]["rows"].size
    closure = props["closure"]["rows"].find { |c| c["quest_seq"] == 1 }
    assert_equal 1, closure["derives_from_count"]
    assert_equal 1, closure["evidence_count"]
  end

  def test_traversal_adds_the_node_neighborhood_and_derivation_paths
    graph = mint_graph
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/graph",
                             params: {node: graph[:claim_id]})
    $stderr.puts "DBG resp_keys=#{parse_json(body)["props"].keys.inspect}"
    node = parse_json(body)["props"]["node"]
    refute_nil node, "?node=<claim_id> adds the traversal"
    assert_equal graph[:claim_id], node["claim"]["id"]
    ids = node["neighborhood"].map { |h| h["node_id"] }
    assert_includes ids, graph[:evidence_id], "hood() walked the evidence edge"
    assert_includes ids, graph[:parent_id], "hood() walked the derivation"
    # LANDED QUIRK (recorded in the report): hood labels every walked node
    # with the PARENT's node_kind (lib/kquest/queries/neighborhood.rb:40 uses
    # h.node_kind instead of e.next_kind) — the canonical query service is
    # consumed as-is, never re-derived.
    assert node["derivation_paths"]["terminals"].any? { |t| t["node_id"] == graph[:parent_id] },
           "paths() reached the TYPED terminal"
  end

  def test_hub_tab_carries_the_reuse_and_type_divergence_rows
    mint_graph
    # A second quest with the same canonical text but a DIFFERENT terminal type
    # — the row tw_hub_divergence reads.
    other_quest = OrchestratorFixtures.mint_quest(conn, user_id: @tenancy[:user_id],
                                                  topic: "the other quest")
    # The SAME canonical text + terminal type in a second quest = the reuse
    # row (quest_count 2); a DIFFERENT terminal type = the divergence row —
    # both over v_canonical_claims.
    reuse = PipelineFixtures.mint_claim(conn, user_id: @tenancy[:user_id],
                                        quest_id: other_quest, seq: 1,
                                        text: "the parent claim")
    conn[:claims].where(id: reuse).update(terminal_type: "primary-empirical",
                                          terminal_basis: "the basis")
    third_quest = OrchestratorFixtures.mint_quest(conn, user_id: @tenancy[:user_id],
                                                  topic: "the third quest")
    divergent = PipelineFixtures.mint_claim(conn, user_id: @tenancy[:user_id],
                                            quest_id: third_quest, seq: 1,
                                            text: "the parent claim")
    conn[:claims].where(id: divergent).update(terminal_type: "residual-uncertainty",
                                              terminal_basis: "divergent basis")
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/graph")
    hub = parse_json(body)["props"]["hub"]
    assert hub["type_divergent"]["rows"].any? { |r| r["canonical_text"] == "the parent claim" },
           "the type-divergence rows over v_canonical_claims (tw_hub_divergence's feed)"
    assert hub["reused"]["rows"].any? { |r| r["quest_count"] == 2 },
           "the reuse rows (the same canonical text across quests)"
  ensure
    conn[:claims].where(quest_id: other_quest).delete if other_quest
    conn[:quests].where(id: other_quest).delete if other_quest
    if third_quest
      conn[:claims].where(quest_id: third_quest).delete
      conn[:quests].where(id: third_quest).delete
    end
  end

  def test_conflicts_docket_is_read_only
    claim_id = PipelineFixtures.mint_claim(conn, user_id: @tenancy[:user_id],
                                           quest_id: @tenancy[:quest_id], seq: 1, text: "c")
    conflict_id = conn[:conflicts].insert(user_id: @tenancy[:user_id],
                                          quest_id: @tenancy[:quest_id], claim_id: claim_id,
                                          divergence: "the sources disagree")
    source = OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                              quest_id: @tenancy[:quest_id], snapshot: "y" * 10)
    conn[:conflict_sources].insert(conflict_id: conflict_id, source_id: source[:id],
                                   user_id: @tenancy[:user_id], source_anchorable: true)
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/graph")
    conflicts = parse_json(body)["props"]["conflicts"]
    assert_equal 1, conflicts["conflicts"]["rows"].size
    assert_equal "the sources disagree", conflicts["conflicts"]["rows"].first["divergence"]
    assert_equal 1, conflicts["sources"].size
  ensure
    conn[:conflict_sources].where(conflict_id: conflict_id).delete if conflict_id
    conn[:conflicts].where(id: conflict_id).delete if conflict_id
    conn[:quest_sources].where(source_id: source[:id]).delete if source
    conn[:sources].where(id: source[:id]).delete if source
  end

  def test_listings_are_capped_with_telemetry
    seed_listing_cap("graph", 1)
    mint_graph
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/graph")
    claims = parse_json(body)["props"]["claims"]
    assert_equal 1, claims["rows"].size
    assert_equal 2, claims["requested"]
    assert_equal 1, claims["cap"]
    telemetry = conn[:cap_records].where(user_id: @tenancy[:user_id], surface: "graph")
    assert telemetry.count >= 1
  end

  def test_invisible_quest_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = inertia_get("/quests/#{other[:quest_id]}/graph")
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end
end
