# frozen_string_literal: true

require_relative "../test_helper"
require "fast/completions"
require_relative "../support/pipeline_fixtures"
require_relative "../support/mock_completions_server"

# The SessionSupervisor — quest-scoped session lifecycle (I04 §5). FM-02's
# supervisor leg / FM-16 / FM-19 / FM-21 / E-1W / E-PAUSE / E-CEIL land here.
# All keyless.
class SessionSupervisorTest < Minitest::Test
  HARNESS_FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/harness.md", __dir__)

  def self.frozen_refusal(section)
    text = File.read(HARNESS_FIXTURE)
    body = text.split("### refusal: #{section}\n").fetch(1)
    body[/```\n(.*?)\n```/m].delete_prefix("```\n").delete_suffix("\n```").strip
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @mock = MockCompletionsServer.new.start
    @tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    @quest_id = @tenancy[:quest_id]
    @phase_id = @tenancy[:phase_id]
    @supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn)
  end

  def teardown
    @mock&.stop
    Kquest::Engine::SessionSupervisor.registry_clear
    PipelineFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  def launch(mode: "autonomous", driver: "orchestrator", model: "engine-test-model")
    @supervisor.launch(user_id: @user_id, quest_id: @quest_id, phase_id: @phase_id,
                       mode: mode, driver: driver, model: model)
  end

  # FM-16 / E-1W — a second launch against a held quest is refused LOUDLY,
  # naming the holder session + driver (byte-matched against the frozen
  # write-guard text).
  def test_FM16_second_launch_refused_naming_holder_and_driver # E-1W
    session_id = launch(driver: "operator")

    error = assert_raises(Kquest::Engine::Error) { launch }
    expected = self.class.frozen_refusal("write-guard")
      .gsub("<quest-id>", @quest_id).gsub("<session-id>", session_id.to_s)
      .gsub("<driver>", "operator")
    assert_equal expected, error.message, "byte-matched against the frozen harness.md template"
  end

  # FM-16 — two RACING launches serialize (the FOR UPDATE gate) and exactly
  # one wins.
  def test_FM16_racing_launches_serialize_and_exactly_one_wins
    conn2 = Sequel.connect(ENV.fetch("DATABASE_URL", "postgres:///kquest_test"))
    begin
      results = Queue.new
      Sync do
        barrier = Async::Task.current
        t1 = barrier.async { results << {winner: launch} }
        t2 = barrier.async do
          sup2 = Kquest::Engine::SessionSupervisor.new(conn: conn2)
          results << {winner: sup2.launch(user_id: @user_id, quest_id: @quest_id,
                                          phase_id: @phase_id, mode: "autonomous",
                                          driver: "orchestrator", model: "engine-test-model")}
        rescue Kquest::Engine::Error => e
          results << {refused: e.message[0, 60]}
        end
        t1.wait
        t2.wait
      end
      outcomes = 2.times.map { results.pop }

      assert_equal 1, outcomes.count { |o| o.key?(:winner) }, "exactly one launch wins"
      assert_equal 1, outcomes.count { |o| o.key?(:refused) }, "the racer is refused"
    ensure
      conn2.disconnect
    end
  end

  # FM-19 / E-PAUSE — the boundary delivery banks the in-flight turn (the
  # ledgered active → paused transition); the mid-turn delivery cancels:
  # CancelledError, NO phantom terminal, the half-streamed turn never
  # appended, committed mutations survive.
  def test_FM19_pause_at_the_boundary_banks_and_mid_turn_cancels # E-PAUSE
    # ── the boundary delivery ─────────────────────────────────────────
    session_id = launch
    @supervisor.request_pause!(@quest_id)

    assert @supervisor.pause_requested?(@quest_id)
    @supervisor.pause_quest!(user_id: @user_id, quest_id: @quest_id, note: "boundary pause")

    assert_equal "paused", conn[:quests].where(id: @quest_id).get(:state)
    event = conn[:quest_lifecycle_events].where(quest_id: @quest_id).first
    assert_equal ["active", "paused"], [event[:from_state], event[:to_state]]
    refute @supervisor.pause_requested?(@quest_id), "the delivered pause clears its flag"

    # ── the mid-turn delivery (cancel; no phantom terminal) ───────────
    conn[:quests].where(id: @quest_id).update(state: "active") # resume
    @supervisor.bank_session!(session_id: session_id) # the banked in-flight turn's session ends
    session_id2 = launch(model: "engine-test-model")
    conn[:llm_providers].where(name: "pause-provider").delete
    conn[:llm_providers].insert(name: "pause-provider", base_url: @mock.url, api_key_ref: nil,
                                model_id: "engine-test-model", context_window: 8192,
                                max_tokens: 512, reasoning: false, max_retries: 0)
    row = conn[:llm_providers].where(name: "pause-provider").first
    session = {id: session_id2, user_id: @user_id, quest_id: @quest_id, phase_id: @phase_id,
               model: row[:model_id]}
    desk = Kquest::Engine::ProviderDesk.new(conn: conn, provider_row: row, session: session)
    ledger = Kquest::Engine::TranscriptLedger.new(conn: conn, session: session)
    chat = Fast::Completions::Chat.new(client: desk.client, model: desk.model)
    chat.with_instructions("i")
    @mock.script([{type: :slow_ttfb, delay: 10}])

    raised = nil
    Sync do
      task = Async do |parent|
        parent.async do
          sleep 0.3
          @supervisor.cancel_now!(chat) # the mid-turn delivery
        end
        begin
          chat.step
        rescue Fast::Completions::CancelledError => e
          raised = e
        end
      end
      task.wait
    end

    assert_instance_of Fast::Completions::CancelledError, raised
    assert_equal 0, ledger.bytes, "the half-streamed turn was never appended (no phantom terminal)"
    assert_equal 0, ledger.sink.blobs.values.join.split("\n").count,
                 "no transcript line at all — committed mutations survive, nothing else lands"
  ensure
    desk&.close
  end

  # FM-21 — the reaper: an orphaned `ended_at IS NULL` row is reaped
  # (stamped); after reaping the launch gate is open again; the successor
  # session reconstructs from store-backed reads only.
  def test_FM21_orphans_are_reaped_and_the_gate_reopens
    session_id = launch
    # the owner "dies": the in-process registry forgets the session
    Kquest::Engine::SessionSupervisor.registry.delete(session_id)

    reaped = @supervisor.reap_orphans!
    assert_includes reaped, session_id
    refute_nil conn[:sessions].where(id: session_id).get(:ended_at), "the orphan is stamped"

    session_id2 = launch # the gate is open again — the cold-boot restart path
    refute_nil session_id2
  end

  # FM-21 / L7 — the cold-boot protocol: store-backed reads ONLY.
  def test_FM21_cold_boot_reconstructs_from_store_backed_reads_only
    session_id = launch
    boot = @supervisor.cold_boot(quest_id: @quest_id)

    assert_equal [:claims, :frontier, :unmined_sources], boot.keys
    assert boot[:claims].is_a?(Array) && boot[:frontier].is_a?(Array) && boot[:unmined_sources].is_a?(Array)
    # the reads ARE the views (store-backed, not in-memory state)
    assert_equal 0, boot[:claims].size
  end

  # FM-02 supervisor leg / E-CEIL — the hard ceiling ends the session at the
  # boundary and the durable state names the two options (A/B — DR-06's menu).
  def test_FM02_hard_ceiling_ends_the_session_with_the_menu_record # E-CEIL
    session_id = launch
    menu = {ceiling: "hard", options: ["A swap-at-the-wall", "B compact-and-continue"]}
    @supervisor.end_at_ceiling!(session_id: session_id, phase_id: @phase_id, menu_record: menu)

    refute_nil conn[:sessions].where(id: session_id).get(:ended_at), "the session ends at the boundary"
    result = conn[:phases].where(id: @phase_id).get(:result)
    assert_equal menu["options"] || menu[:options], result["ceiling"]["options"],
                 "the durable state names options A and B — the runtime operator decides"
  end

  # L13 — orchestrator vs operator launch modes write sessions.driver.
  def test_launch_modes_write_the_driver_column
    assert_equal "orchestrator", conn[:sessions].where(id: launch).get(:driver)
    Kquest::Engine::SessionSupervisor.registry_clear

    # a separate quest holds the operator launch (one writer PER QUEST)
    quest2 = conn[:quests].insert(user_id: @user_id, topic: "second quest",
                                  web_call_budget: 1, token_budget: 1, spend_budget_usd: 1.0)
    phase2 = conn[:phases].insert(user_id: @user_id, quest_id: quest2, kind: "decompose")
    @quest_id = quest2
    @phase_id = phase2
    assert_equal "operator", conn[:sessions].where(id: launch(driver: "operator")).get(:driver)

    error = assert_raises(Kquest::Engine::Error) do
      @supervisor.launch(user_id: @user_id, quest_id: quest2, phase_id: phase2,
                         mode: "autonomous", driver: "banana", model: "m")
    end
    assert_match(/not a launch mode/, error.message)
  end
end
