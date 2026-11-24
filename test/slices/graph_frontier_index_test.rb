# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# GET /quests/:quest_id/frontier — the frontier inspector (I16 Part 5): the
# mass fuse, closure classes, aging bands, the OVERHANG BADGE, server-side
# filter/sort, ALL CAPPED, and the visibility gate on both sides.
class GraphFrontierIndexTest < Minitest::Test
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

  def mint_frontier(need:, uncertainty: 3, relevance: 3, state: "open", seq: nil)
    claim_id = PipelineFixtures.mint_claim(conn, user_id: @tenancy[:user_id],
                                           quest_id: @tenancy[:quest_id],
                                           seq: seq || (conn[:claims].where(quest_id: @tenancy[:quest_id]).count + 1),
                                           text: "claim #{need}")
    phase_id = conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    kind: "descent",
                                    round_no: conn[:phases].where(quest_id: @tenancy[:quest_id]).count + 1)
    conn[:frontier_entries].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                   claim_id: claim_id, need: need, uncertainty: uncertainty,
                                   relevance: relevance, spawned_by_phase_id: phase_id,
                                   state: state, closed_at: state == "closed" ? Time.now : nil,
                                   closure_type: state == "closed" ? "fetch" : nil)
  end

  def test_owner_renders_the_frontier_page_object
    mint_frontier(need: "a primary on X", uncertainty: 4, relevance: 5)
    status, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/frontier")
    assert_equal 200, status
    data = parse_json(body)
    assert_equal "Frontier/Index", data["component"]
    props = data["props"]
    assert_equal({"open_entries" => 1, "mass" => 20}, props["mass"], "the mass fuse reading")
    assert_equal 1, props["listing"]["rows"].size
    assert_equal "a primary on X", props["listing"]["rows"].first["need"]
    assert_equal 20, props["listing"]["rows"].first["mass"]
  end

  def test_capped_with_showing_fields_and_telemetry
    seed_listing_cap("frontier", 2)
    mint_frontier(need: "n1", uncertainty: 2, relevance: 2)
    mint_frontier(need: "n2", uncertainty: 5, relevance: 5, seq: 2)
    mint_frontier(need: "n3", uncertainty: 1, relevance: 1, seq: 3)
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/frontier")
    listing = parse_json(body)["props"]["listing"]
    assert_equal 2, listing["rows"].size
    assert_equal 3, listing["requested"]
    assert_equal 2, listing["cap"]
    assert_equal "n2", listing["rows"].first["need"], "the mass fuse order (default)"
    telemetry = conn[:cap_records].where(user_id: @tenancy[:user_id], surface: "frontier")
    assert telemetry.count >= 1
    assert_equal @tenancy[:quest_id], telemetry.first[:quest_id]
  end

  def test_the_overhang_badge_reads_the_rollup_for_this_surface
    Kquest::Ui::CapRecords.record!(conn, user_id: @tenancy[:user_id], surface: "frontier",
                                   requested: 90, cap: 50, existed: 90)
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/frontier")
    badge = parse_json(body)["props"]["overhang"]
    assert_equal "frontier", badge["surface"]
    assert_equal 40, badge["overhang"]
  ensure
    conn[:cap_records].where(user_id: @tenancy[:user_id]).delete
  end

  def test_closure_classes_and_aging_bands_render
    mint_frontier(need: "open one")
    mint_frontier(need: "closed one", state: "closed", seq: 2)
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/frontier")
    props = parse_json(body)["props"]
    classes = props["closure_classes"].map { |c| [c["state"], c["n"]] }.to_h
    assert_equal 1, classes["open"]
    assert_equal 1, classes["closed"]
    assert props["aging_bands"].key?("under_1d"), "the aging_open_needs shape's bands"
    assert_equal 1, props["aging_bands"]["under_1d"].to_i, "the aging bands count the OPEN set"
  end

  def test_state_filter_and_sort_params_are_server_side
    mint_frontier(need: "open one")
    mint_frontier(need: "closed one", state: "closed", seq: 2)
    _, _, body = inertia_get("/quests/#{@tenancy[:quest_id]}/frontier", params: {state: "closed"})
    listing = parse_json(body)["props"]["listing"]
    assert_equal 1, listing["rows"].size
    assert_equal "closed one", listing["rows"].first["need"]
    refute_nil listing["rows"].first["closure_type"]
  end

  def test_invisible_quest_is_404
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    status, = inertia_get("/quests/#{other[:quest_id]}/frontier")
    assert_equal 404, status
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end
end
