# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# The ONE operator-write door (I17 Part 0.1): the owner gate (404 posture —
# existence never leaked), the launch gate through the LANDED
# SessionSupervisor (FM-16 verbatim; the decompose round-1 mint per I01
# DR-13), the SAME-TRANSACTION audit through the LANDED
# TranscriptLedger#record_tool_call! (refusals audited ok=false), the
# tool_calls-shaped record! for tool-less writes, and the ended_at stamp
# (the DR-04 sign-off).
class OperatorWriteTest < Minitest::Test
  def setup
    OrchestratorFixtures.sweep_all(conn)
    Kquest::Engine::SessionSupervisor.registry_clear
    @tenancy = OrchestratorFixtures.mint_tenancy(conn) # quest only — NO phases row
  end

  def teardown
    Kquest::Engine::SessionSupervisor.registry_clear
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  # jsonb columns arrive as String or Hash depending on the extension's load
  # state — the landed normalize idiom (the create-quest test's own shape).
  def json_of(value)
    JSON.parse(value.is_a?(String) ? value : value.to_json)
  end

  def user = {id: @tenancy[:user_id], username: "operator-fixture"}

  def quest
    @quest ||= conn[:quests].where(id: @tenancy[:quest_id]).first
  end

  def test_owner_gate_selects_by_id_and_user_only
    row = Kquest::Ui::OperatorWrite.owner_quest!(conn, user_id: @tenancy[:user_id],
                                                 quest_id: @tenancy[:quest_id])
    refute_nil row, "the owner sees the row"
    other = OrchestratorFixtures.mint_quest(conn, user_id: @tenancy[:user_id])
    assert_nil Kquest::Ui::OperatorWrite.owner_quest!(
      conn, user_id: SecureRandom.uuid, quest_id: other
    ), "a non-owner gets nil — the action 404s BEFORE any prop assembly (existence never leaked)"
    assert_nil Kquest::Ui::OperatorWrite.owner_quest!(
      conn, user_id: @tenancy[:user_id], quest_id: SecureRandom.uuid
    ), "an absent quest is nil, never a leak"
  end

  def test_open_session_mints_the_decompose_round_one_phase_and_launches_interactive
    session = Kquest::Ui::OperatorWrite.open_session!(conn, user: user, quest: quest)
    assert_equal "operator", session.fetch(:driver)
    assert_equal "interactive", session.fetch(:mode)
    assert_nil session.fetch(:ended_at), "the session is LIVE"
    phases = conn[:phases].where(quest_id: @tenancy[:quest_id]).to_a
    assert_equal 1, phases.size, "the binding phase row is minted ONCE (I01 DR-13)"
    assert_equal "decompose", phases.first.fetch(:kind)
    assert_equal 1, phases.first.fetch(:round_no)
    assert_equal 1, phases.first.fetch(:attempt_no)
    assert_equal "pending", phases.first.fetch(:state)
    assert_equal phases.first.fetch(:id), session.fetch(:phase_id)
    assert_includes Kquest::Engine::SessionSupervisor.registry, session.fetch(:id),
                    "the reused-or-minted session is claimed into liveness"
  end

  def test_open_session_reuses_the_open_operator_session_and_claims_it_into_liveness
    first = Kquest::Ui::OperatorWrite.open_session!(conn, user: user, quest: quest)
    Kquest::Engine::SessionSupervisor.registry_clear
    second = Kquest::Ui::OperatorWrite.open_session!(conn, user: user, quest: quest)
    assert_equal first.fetch(:id), second.fetch(:id), "REUSE — never a second session"
    assert_equal 1, conn[:sessions].where(quest_id: @tenancy[:quest_id]).count
    assert_includes Kquest::Engine::SessionSupervisor.registry, first.fetch(:id),
                    "the reused row is claimed into liveness"
    assert_equal first.fetch(:phase_id), second.fetch(:phase_id)
  end

  def test_open_session_refuses_with_the_frozen_write_guard_when_another_writer_holds
    phase_id = conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    kind: "decompose")
    holder = conn[:sessions].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    phase_id: phase_id, mode: "autonomous",
                                    driver: "orchestrator", model: "test-model")
    Kquest::Engine::SessionSupervisor.registry << holder

    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.open_session!(conn, user: user, quest: quest)
    end
    assert_equal "WriteGuard", error.error_class
    # FM-16 verbatim: the supervisor's own words name the holder session + driver.
    assert_equal Kquest::Engine::SessionSupervisor.new(conn: conn).write_guard_refusal(
      quest_id: @tenancy[:quest_id], session_id: holder, driver: "orchestrator"
    ), error.message
    assert_empty conn[:sessions].where(driver: "operator"),
                 "no operator session was minted behind the refusal"
  end

  def test_write_runs_the_guard_the_landed_tool_and_the_audit_in_one_transaction
    session = Kquest::Ui::OperatorWrite.open_session!(conn, user: user, quest: quest)
    claim = PipelineFixtures.mint_claim(conn, user_id: @tenancy[:user_id],
                                        quest_id: @tenancy[:quest_id], seq: 1, text: "a claim")
    outcome = Kquest::Ui::OperatorWrite.write!(
      conn, session: session, tool_name: "frontier_add",
      args: {claim: "K1", need: "a need", uncertainty: 4, relevance: 5}
    )
    assert outcome.fetch(:ok), outcome.fetch(:outcome)
    assert_includes outcome.fetch(:outcome), "frontier entry opened"
    assert_nil outcome.fetch(:error_class)
    assert_equal 1, conn[:frontier_entries].where(quest_id: @tenancy[:quest_id]).count,
                 "the LANDED tool made the write"
    audit = conn[:tool_calls].where(session_id: session.fetch(:id)).first
    refute_nil audit, "the audit row rode the SAME transaction"
    assert_equal "frontier_add", audit.fetch(:tool)
    assert_equal true, audit.fetch(:ok)
    assert_nil audit.fetch(:error_class), "the I01 shape law: ok ⇒ error_class nil"
  end

  def test_tool_refusals_are_audited_ok_false_with_the_rule_id_and_returned_teaching
    session = Kquest::Ui::OperatorWrite.open_session!(conn, user: user, quest: quest)
    PipelineFixtures.mint_claim(conn, user_id: @tenancy[:user_id],
                                quest_id: @tenancy[:quest_id], seq: 1, text: "a claim")
    Kquest::Ui::OperatorWrite.write!(conn, session: session, tool_name: "frontier_add",
                                     args: {claim: "K1", need: "a need", uncertainty: 4, relevance: 5})
    outcome = Kquest::Ui::OperatorWrite.write!(
      conn, session: session, tool_name: "frontier_add",
      args: {claim: "K1", need: "a different need", uncertainty: 2, relevance: 3}
    )
    refute outcome.fetch(:ok), "the re-add refusal (uq_frontier_open_per_claim) is the outcome"
    assert_includes outcome.fetch(:outcome), "REFUSAL", "the landed refusal text, verbatim"
    refute_nil outcome.fetch(:error_class), "the census-able rule-id is the error_class"
    refusal = conn[:tool_calls].where(session_id: session.fetch(:id), ok: false).first
    refute_nil refusal, "refusals are audited ok=false"
    assert_equal outcome.fetch(:error_class), refusal.fetch(:error_class)
    assert_equal true, json_of(refusal.fetch(:result))["is_error"],
                 "the audited refusal result carries the teaching text as an error"
    assert_equal 1, conn[:frontier_entries].where(quest_id: @tenancy[:quest_id]).count,
                 "the first write holds the entry — the refusal added no second one"
  end

  def test_write_guard_refusal_inside_write_is_returned_without_an_audit_row
    # The holder must sort BEFORE our session row so live_holder returns it
    # (insertion order): plant the orchestrator writer first, then the
    # session we attempt the write through.
    phase_id = conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    kind: "decompose")
    holder = conn[:sessions].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                    phase_id: phase_id, mode: "autonomous",
                                    driver: "orchestrator", model: "test-model")
    Kquest::Engine::SessionSupervisor.registry << holder
    session = conn[:sessions].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                     phase_id: phase_id, mode: "interactive",
                                     driver: "operator", model: "operator")
    # OUR row is deliberately NOT claimed into liveness — live_holder then
    # deterministically resolves to the planted holder regardless of the
    # sessions heap order (the full suite's insertion order is not stable).
    session_row = conn[:sessions].where(id: session).first
    outcome = Kquest::Ui::OperatorWrite.write!(conn, session: session_row, tool_name: "status",
                                               args: {})
    refute outcome.fetch(:ok)
    assert_equal "WriteGuard", outcome.fetch(:error_class)
    assert_empty conn[:tool_calls].where(session_id: session),
                 "no tool call was made — the refusal names the OTHER holder, no second ledger row"
  end

  def test_record_writes_the_tool_calls_shaped_audit_in_the_callers_transaction
    session = Kquest::Ui::OperatorWrite.open_session!(conn, user: user, quest: quest)
    conn.transaction do
      Kquest::Ui::OperatorWrite.record!(
        conn, session: session, tool: "briefing_agenda",
        args: {url: "https://example.test/a"}, result: {content: "staged", is_error: false},
        ok: true
      )
    end
    row = conn[:tool_calls].where(session_id: session.fetch(:id), tool: "briefing_agenda").first
    refute_nil row, "the tool-less write's audit row"
    assert_equal true, row.fetch(:ok)
    assert_equal "staged", json_of(row.fetch(:result))["content"]
  end

  def test_end_session_stamps_ended_at_and_releases_liveness_then_refuses
    session = Kquest::Ui::OperatorWrite.open_session!(conn, user: user, quest: quest)
    ended = Kquest::Ui::OperatorWrite.end_session!(conn, quest_id: @tenancy[:quest_id])
    refute_nil conn[:sessions].where(id: session.fetch(:id)).first.fetch(:ended_at),
               "the DR-04 sign-off stamps ended_at"
    refute_includes Kquest::Engine::SessionSupervisor.registry, session.fetch(:id),
                    "the liveness claim is released — the doors are open again"
    assert_equal session.fetch(:id), ended.fetch(:id)
    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.end_session!(conn, quest_id: @tenancy[:quest_id])
    end
    assert_match(/no open operator session/, error.message, "the teaching refusal")
  end

  def test_open_session_binds_the_latest_phase_when_the_quest_has_phases
    # The report tools' schema law (fk_report_versions_phase pins the
    # synthesis_phase_id to a kind-synthesis phase) makes the LATEST phase
    # the binding row whenever one exists.
    conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id], kind: "decompose")
    later = conn[:phases].insert(user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
                                 kind: "synthesis")
    session = Kquest::Ui::OperatorWrite.open_session!(conn, user: user, quest: quest)
    assert_equal later, session.fetch(:phase_id), "the latest phase is the binding row"
    assert_equal 2, conn[:phases].where(quest_id: @tenancy[:quest_id]).count,
                 "no extra phase was minted"
  end
end
