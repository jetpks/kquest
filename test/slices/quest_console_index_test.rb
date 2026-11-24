# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require_relative "../support/orchestrator_fixtures"

# GET /quests/:quest_id/console — the steering console (I17 Part 1): the
# owner gate on both sides (404 non-owner BEFORE any prop assembly), the
# parity line composed through the shared formatter, the menus derived from
# durable state, the capped listings with telemetry (surface `console`),
# the ?alert= pre-load pointer, and the empty state's generic set.
class QuestConsoleIndexTest < Minitest::Test
  include ActionTestHelper

  def setup
    OrchestratorFixtures.sweep_all(conn)
    setup_db
    OmniAuth.config.test_mode = true
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    seed_listing_cap("console", 2)
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
    sign_in(Owner.new(id: row[:id], github_uid: row[:github_uid], username: row[:username],
                      name: row[:name], email: row[:email], avatar_url: row[:avatar_url]))
  end

  def seed_listing_cap(surface, cap)
    key = "ui.listing_cap.#{surface}"
    conn[:tool_config].where(key: key).delete
    conn[:tool_config].insert(key: key, num_value: cap, text_value: nil,
                              provenance: "test data (the seeds re-heal at the next prepare)")
  end

  def console_get(params: {})
    inertia_get("/quests/#{@tenancy[:quest_id]}/console", params: params)
  end

  def mint_orchestrator_stop(note, state: "paused")
    conn[:quests].where(id: @tenancy[:quest_id]).update(state: state)
    conn[:quest_lifecycle_events].insert(
      user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
      from_state: "active", to_state: state, actor: "orchestrator",
      occurred_at: Time.now, note: note
    )
  end

  def test_owner_renders_the_console_page_object_with_the_shared_parity_line
    status, _, body = console_get
    assert_equal 200, status
    props = parse_json(body)["props"]
    assert_equal "Quests/Console", parse_json(body)["component"]
    assert_equal @tenancy[:quest_id], props["quest"]["id"]
    assert_match(/\Aquest_status: quest=/, props["parity_line"],
                 "the parity line composes through the SHARED QuestStatus.line")
    assert_equal "/quests/#{@tenancy[:quest_id]}/stream", props["stream_url"],
                 "the I15 frozen stream URL mounts the live view"
    assert_nil props["session"], "no open operator session day one"
    assert_kind_of Array, props["menus"]
    assert_kind_of Array, props["stop_rules"], "the crossed stop_rules rows are echoed"
    refute_empty props["stop_rules"], "the 19 seeded stop_rules rows are the menus' evidence"
    assert props["ladder_passes"].key?("rows"), "the ladder evidence is a capped listing"
  end

  def test_active_quest_derives_no_menus_the_live_view_plus_the_pause_button
    _, _, body = console_get
    assert_empty parse_json(body)["props"]["menus"],
                 "I08 §5.2: while active NO menu — the console is the live view + pause"
  end

  def test_paused_quest_with_a_process_stop_note_derives_the_trigger_menu
    mint_orchestrator_stop(
      "PROCESS_STOP: SR-16 at phase 2 (descent) — hard bytes — route: pause-and-present"
    )
    _, _, body = console_get
    menus = parse_json(body)["props"]["menus"]
    ids = menus.map { |m| m["id"] }
    assert_includes ids, "transcript-ceiling"
    menu = menus.find { |m| m["id"] == "transcript-ceiling" }
    assert_equal "SR-16", menu["evidence"]["stop_rule"]["rule_id"],
                 "the evidence ECHOES the crossed stop_rules row"
    assert_equal "engine.transcript_ceiling_hard_bytes", menu["evidence"]["stop_rule"]["config_key"]
    assert_includes ids, "model-qualification", "ANY pause carries the routing editor"
    assert(menus.flat_map { |m| m["options"] }.all? { |o| o.keys == %w[id label] },
           "no option is pre-picked/defaulted/timed out anywhere in the shape")
  end

  def test_empty_state_renders_the_generic_set_without_fabricating_a_trigger
    conn[:quests].where(id: @tenancy[:quest_id]).update(state: "paused")
    _, _, body = console_get
    assert_equal ["model-qualification"], parse_json(body)["props"]["menus"].map { |m| m["id"] },
                 "Grounds §6.7: no orchestrator note — the generic set only"
  end

  def test_the_alert_param_preloads_the_adjudication_pointer
    conn[:quests].where(id: @tenancy[:quest_id]).update(state: "paused")
    _, _, body = console_get(params: {alert: "tw_churn"})
    menu = parse_json(body)["props"]["menus"].find { |m| m["id"] == "adjudication" }
    refute_nil menu, "the ?alert= param pre-loads the adjudication pointer"
    assert_equal "tw_churn", menu["evidence"]["alert"]
    assert_equal true, menu["evidence"]["muteable"]
  end

  def test_listings_are_capped_with_showing_fields_and_telemetry
    mint_orchestrator_stop("PROCESS_STOP: SR-16 at phase 1 (decompose) — x — route: pause-and-present")
    2.times do |i|
      conn[:quest_lifecycle_events].insert(
        user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
        from_state: "active", to_state: "paused", actor: "orchestrator",
        occurred_at: Time.now - (i * 60), note: "older event #{i}"
      )
    end
    _, _, body = console_get
    lifecycle = parse_json(body)["props"]["lifecycle"]
    assert_equal 2, lifecycle["rows"].size, "the surface cap is 2 (seeded in setup)"
    assert_equal 3, lifecycle["requested"]
    assert_equal 2, lifecycle["cap"]
    telemetry = conn[:cap_records].where(user_id: @tenancy[:user_id], surface: "console")
    assert telemetry.count >= 1, "one telemetry row per capped listing request"
    assert_equal @tenancy[:quest_id], telemetry.first[:quest_id]
  end

  def test_the_quest_mute_rows_render_with_key_and_provenance
    conn[:tool_config].insert(key: "alerts.mute.#{@tenancy[:quest_id]}.tw_churn",
                              text_value: "slow local model",
                              provenance: "operator u1 2026-11-25T00:00:00Z — slow local model")
    _, _, body = console_get
    mutes = parse_json(body)["props"]["mutes"]
    assert_equal 1, mutes["rows"].size
    assert_equal "slow local model", mutes["rows"].first["text_value"]
  ensure
    conn[:tool_config].where(Sequel.like(:key, "alerts.mute.%")).delete
  end

  def test_non_owner_is_404_before_any_prop_assembly
    other = OrchestratorFixtures.mint_tenancy(conn, topic: "not yours")
    before = conn[:cap_records].where(surface: "console").count
    status, = inertia_get("/quests/#{other[:quest_id]}/console")
    assert_equal 404, status, "existence is never leaked (the OWNER gate)"
    assert_equal before, conn[:cap_records].where(surface: "console").count,
                 "no prop assembly happened behind the 404"
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: other[:user_id]) if other
  end

  def test_absent_quest_is_404
    status, = inertia_get("/quests/#{SecureRandom.uuid}/console")
    assert_equal 404, status
  end

  def test_anonymous_redirects_to_sign_in
    sign_out
    status, headers, = console_get
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_no_process_is_ever_spawned
    Process.stub(:spawn, ->(*_args) { flunk "the UI never spawns — the launcher owns worker boot" }) do
      console_get
    end
  end
end
