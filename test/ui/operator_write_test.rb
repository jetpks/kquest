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
    # The I19 tables are NOT in the landed sweeps (the I16 seam) — per-test
    # ensure-sweeps in reverse-FK order: grants → members → workspaces.
    conn[:resource_grants].delete
    conn[:workspace_members].delete
    conn[:workspaces].delete
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
    OrchestratorFixtures.cleanup(conn, user_id: @mate_id) if @mate_id
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

  # ── the enqueue door (I18 Spec Part 2.1 / AC6) ─────────────────────────

  def test_enqueue_turn_inserts_one_enqueued_row_with_the_per_session_seq
    session = Kquest::Ui::OperatorWrite.open_session!(conn, user: user, quest: quest)
    first = Kquest::Ui::OperatorWrite.enqueue_turn!(conn, session: session, body: "what is the scope?")
    second = Kquest::Ui::OperatorWrite.enqueue_turn!(conn, session: session, body: "  padded  ")
    assert_equal 1, first
    assert_equal 2, second, "the seq is per-session max+1 (the record_tool_call! pattern)"
    rows = conn[:briefing_turns].where(session_id: session.fetch(:id)).order(:seq).to_a
    assert_equal 2, rows.size
    assert_equal [1, 2], rows.map { |r| r[:seq] }
    assert_equal ["what is the scope?", "padded"], rows.map { |r| r[:body] }
    assert rows.all? { |r| r[:state] == "enqueued" }
    assert_nil rows.first[:consumed_at]
    assert_equal @tenancy[:user_id], rows.first[:user_id]
    assert_equal @tenancy[:quest_id], rows.first[:quest_id]
  end

  def test_enqueue_turn_refuses_a_blank_body_teaching_with_no_row
    session = Kquest::Ui::OperatorWrite.open_session!(conn, user: user, quest: quest)
    ["", "   ", nil].each do |blank|
      error = assert_raises(Kquest::Engine::Error) do
        Kquest::Ui::OperatorWrite.enqueue_turn!(conn, session: session, body: blank)
      end
      assert_match(/empty/, error.message, "the refusal teaches")
    end
    assert_empty conn[:briefing_turns].where(session_id: session.fetch(:id)).to_a,
                 "the refusal precedes any insert (the CHECK law taught, never tripped)"
  end

  def test_end_session_marks_still_enqueued_turns_skipped
    session = Kquest::Ui::OperatorWrite.open_session!(conn, user: user, quest: quest)
    Kquest::Ui::OperatorWrite.enqueue_turn!(conn, session: session, body: "first")
    Kquest::Ui::OperatorWrite.enqueue_turn!(conn, session: session, body: "second")
    Kquest::Ui::OperatorWrite.end_session!(conn, quest_id: @tenancy[:quest_id])
    states = conn[:briefing_turns].where(session_id: session.fetch(:id)).order(:seq).select_map(:state)
    assert_equal %w[skipped skipped], states,
                 "the dead-letter mark: an ended session never consumes — never silently dropped"
  end

  def test_the_dead_letter_mark_covers_a_governor_banked_sessions_leftover_turns
    # Carry-forward (a) / lane 1 PH0-10: the governor's loud path banks the
    # operator session THROUGH bank_session! (ended_at stamped, the engine's
    # own law) — end_session! never ran, so the session's still-enqueued
    # turns stay enqueued and can never be consumed (the row is closed; the
    # runner's branch serves OPEN sessions only). The dead-letter mark keys
    # the QUEST's operator sessions, so the NEXT sign-off reaches them.
    banked = Kquest::Ui::OperatorWrite.open_session!(conn, user: user, quest: quest)
    Kquest::Ui::OperatorWrite.enqueue_turn!(conn, session: banked, body: "written before the bank")
    Kquest::Engine::SessionSupervisor.new(conn: conn)
                                     .bank_session!(session_id: banked.fetch(:id))
    assert_equal "enqueued", conn[:briefing_turns]
                                  .where(session_id: banked.fetch(:id)).get(:state),
                 "the bank is the engine's law — the mark is end_session!'s"

    # The operator returns: a NEW session, one fresh turn, then the sign-off.
    reopened = Kquest::Ui::OperatorWrite.open_session!(conn, user: user, quest: quest)
    refute_equal banked.fetch(:id), reopened.fetch(:id)
    Kquest::Ui::OperatorWrite.enqueue_turn!(conn, session: reopened, body: "written after the bank")
    Kquest::Ui::OperatorWrite.end_session!(conn, quest_id: @tenancy[:quest_id])
    by_session = conn[:briefing_turns].to_a.group_by { |r| r[:session_id] }
    assert_equal %w[skipped], by_session.fetch(banked.fetch(:id)).map { |r| r[:state] },
                 "the BANKED session's leftover turn dead-letters at the next sign-off"
    assert_equal %w[skipped], by_session.fetch(reopened.fetch(:id)).map { |r| r[:state] },
                 "the open session's own turn dead-letters too — ONE UPDATE, same door"
  end
  # ── the I19 grant-admin doors (the dashboard's workspace-admin WRITE
  #    half; Spec Part 1) ──────────────────────────────────────────────

  # The I19 fixture mints: workspaces/mates/sources the doors exercise.
  # Sweeps run in teardown in reverse-FK order (grants → members →
  # workspaces → cleanup) — the landed discipline; sweep_all does NOT know
  # the three tables.
  def mint_workspace!(name)
    conn[:workspaces].insert(name: name, created_by_user_id: @tenancy[:user_id])
  end

  def mint_mate!(handle)
    @mate_id ||= conn[:users].insert(handle: handle, github_uid: SecureRandom.uuid,
                                     username: "u#{SecureRandom.hex(6)}", name: "Mate",
                                     created_at: Time.now)
  end

  def mint_operator_source!
    OrchestratorFixtures.mint_source(conn, user_id: @tenancy[:user_id],
                                     quest_id: @tenancy[:quest_id],
                                     snapshot: "grant-admin fixture text")
  end

  def test_owned_workspace_and_owned_grant_select_by_id_and_owner_only
    ws_id = mint_workspace!("ws-own-#{SecureRandom.hex(4)}")
    row = Kquest::Ui::OperatorWrite.owned_workspace!(conn, user_id: @tenancy[:user_id],
                                                     workspace_id: ws_id)
    refute_nil row, "the owner sees the workspace"
    assert_nil Kquest::Ui::OperatorWrite.owned_workspace!(
      conn, user_id: SecureRandom.uuid, workspace_id: ws_id
    ), "a non-owner gets nil — the action 404s BEFORE any mutation (existence never leaked)"
    assert_nil Kquest::Ui::OperatorWrite.owned_workspace!(
      conn, user_id: @tenancy[:user_id], workspace_id: SecureRandom.uuid
    ), "an absent workspace is nil, never a leak"

    source = mint_operator_source!
    grant_id = conn[:resource_grants].insert(owner_user_id: @tenancy[:user_id],
                                             source_id: source[:id], is_public: true,
                                             note: "mine")
    grant = Kquest::Ui::OperatorWrite.owned_grant!(conn, user_id: @tenancy[:user_id],
                                                   grant_id: grant_id)
    refute_nil grant, "ANY scope — the row is the operator's own"
    assert_nil Kquest::Ui::OperatorWrite.owned_grant!(
      conn, user_id: SecureRandom.uuid, grant_id: grant_id
    ), "a non-owner gets nil — existence never leaked"
    assert_nil Kquest::Ui::OperatorWrite.owned_grant!(
      conn, user_id: @tenancy[:user_id], grant_id: SecureRandom.uuid
    ), "an absent grant is nil, never a leak"
  end

  def test_create_workspace_lands_the_row_and_the_creator_membership_in_one_transaction
    name = "ws-create-#{SecureRandom.hex(4)}"
    row = Kquest::Ui::OperatorWrite.create_workspace!(conn, user: user, name: name)
    refute_nil row
    assert_equal name, row.fetch(:name)
    assert_equal @tenancy[:user_id], row.fetch(:created_by_user_id),
                 "the audit carrier: created_by_user_id pins the who"
    membership = conn[:workspace_members].where(workspace_id: row.fetch(:id)).first
    refute_nil membership, "the frozen I02 fixture shape: the creator IS a member"
    assert_equal @tenancy[:user_id], membership.fetch(:user_id)
    refute_nil membership.fetch(:joined_at), "joined_at is the when-carrier"
  end

  def test_create_workspace_teaches_blank_format_and_taken_names_with_no_partial_rows
    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.create_workspace!(conn, user: user, name: "   ")
    end
    assert_equal "name is required", error.message

    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.create_workspace!(conn, user: user, name: "NOT-A-SLUG")
    end
    assert_includes error.message, "name must match", "the slug law taught"
    assert_includes error.message, "ck_workspaces_name", "the CHECK named, never tripped"

    name = "ws-taken-#{SecureRandom.hex(4)}"
    mint_workspace!(name)
    before_members = conn[:workspace_members].count
    before_workspaces = conn[:workspaces].count
    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.create_workspace!(conn, user: user, name: name)
    end
    assert_match(/already exists/, error.message, "uq_workspaces_name is GLOBAL — taught")
    assert_equal before_members, conn[:workspace_members].count,
                 "no partial rows: a refused create lands NO membership row"
    assert_equal before_workspaces, conn[:workspaces].count,
                 "no partial rows: the transaction shape holds"
  end

  def test_rename_workspace_updates_teaches_and_excludes_self_from_uniqueness
    ws = Kquest::Ui::OperatorWrite.create_workspace!(
      conn, user: user, name: "ws-ren-#{SecureRandom.hex(4)}"
    )
    fresh = "ws-ren-#{SecureRandom.hex(4)}"
    renamed = Kquest::Ui::OperatorWrite.rename_workspace!(conn, user: user, workspace: ws,
                                                          name: fresh)
    refute_nil renamed
    assert_equal fresh, renamed.fetch(:name)

    same = Kquest::Ui::OperatorWrite.rename_workspace!(conn, user: user, workspace: ws,
                                                       name: fresh)
    assert_equal fresh, same.fetch(:name),
                 "renaming to its own name is a success — uniqueness excludes self"

    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.rename_workspace!(conn, user: user, workspace: ws, name: "   ")
    end
    assert_equal "name is required", error.message

    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.rename_workspace!(conn, user: user, workspace: ws,
                                                  name: "Bad Slug")
    end
    assert_includes error.message, "ck_workspaces_name"

    other_name = "ws-ren-other-#{SecureRandom.hex(4)}"
    mint_workspace!(other_name)
    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.rename_workspace!(conn, user: user, workspace: ws,
                                                  name: other_name)
    end
    assert_match(/already exists/, error.message)
  end

  def test_add_workspace_member_adds_by_handle_and_teaches_unknown_and_duplicate
    ws = Kquest::Ui::OperatorWrite.create_workspace!(
      conn, user: user, name: "ws-mem-#{SecureRandom.hex(4)}"
    )
    mate = "gh-mate-#{SecureRandom.hex(4)}"
    mate_id = mint_mate!(mate)
    row = Kquest::Ui::OperatorWrite.add_workspace_member!(conn, user: user, workspace: ws,
                                                          handle: mate)
    refute_nil row
    assert_equal mate_id, row.fetch(:user_id)
    assert_equal ws.fetch(:id), row.fetch(:workspace_id)
    refute_nil row.fetch(:joined_at), "joined_at is the membership write's when-carrier"

    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.add_workspace_member!(conn, user: user, workspace: ws,
                                                      handle: "gh-nope-#{SecureRandom.hex(4)}")
    end
    assert_match(/no user with handle/, error.message, "the unknown-handle teaching")

    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.add_workspace_member!(conn, user: user, workspace: ws,
                                                      handle: mate)
    end
    assert_match(/already a member/, error.message, "X40 taught BEFORE the insert")
    assert_equal 1, conn[:workspace_members].where(workspace_id: ws.fetch(:id),
                                                   user_id: mate_id).count,
                 "the duplicate refusal added no second membership row " \
                 "(the creator's own membership row is separate)"
  end

  def test_remove_workspace_member_deletes_and_teaches_not_a_member
    ws = Kquest::Ui::OperatorWrite.create_workspace!(
      conn, user: user, name: "ws-rmm-#{SecureRandom.hex(4)}"
    )
    mate = "gh-mate-#{SecureRandom.hex(4)}"
    mate_id = mint_mate!(mate)
    Kquest::Ui::OperatorWrite.add_workspace_member!(conn, user: user, workspace: ws,
                                                    handle: mate)

    assert_nil Kquest::Ui::OperatorWrite.remove_workspace_member!(
      conn, user: user, workspace: ws, handle: mate
    ), "the removal is row deletion"
    assert_empty conn[:workspace_members].where(workspace_id: ws.fetch(:id), user_id: mate_id),
                 "the membership row is gone"

    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.remove_workspace_member!(conn, user: user, workspace: ws,
                                                         handle: mate)
    end
    assert_match(/is not a member/, error.message, "the mute-remove teaching shape")
    assert_includes error.message, "nothing to remove"
  end

  def test_create_workspace_grant_lands_the_row_with_the_required_note
    ws = Kquest::Ui::OperatorWrite.create_workspace!(
      conn, user: user, name: "ws-grt-#{SecureRandom.hex(4)}"
    )
    source = mint_operator_source!
    grant = Kquest::Ui::OperatorWrite.create_workspace_grant!(
      conn, user: user, workspace: ws, source_urn: source[:urn], note: "the why"
    )
    refute_nil grant
    assert_equal @tenancy[:user_id], grant.fetch(:owner_user_id), "the who-carrier"
    assert_equal source[:id], grant.fetch(:source_id)
    assert_equal ws.fetch(:id), grant.fetch(:grantee_workspace_id)
    assert_equal false, grant.fetch(:is_public)
    assert_equal "the why", grant.fetch(:note), "the why-carrier"
    refute_nil grant.fetch(:granted_at), "the when-carrier"
  end

  def test_create_workspace_grant_teaches_unowned_source_blank_note_and_duplicate
    ws = Kquest::Ui::OperatorWrite.create_workspace!(
      conn, user: user, name: "ws-grt2-#{SecureRandom.hex(4)}"
    )
    source = mint_operator_source!

    # The X38 class: the urn EXISTS but under another owner — taught, never
    # a composite-FK 500.
    mate = "gh-mate-#{SecureRandom.hex(4)}"
    mint_mate!(mate)
    other_quest = OrchestratorFixtures.mint_quest(conn, user_id: @mate_id)
    other_source = OrchestratorFixtures.mint_source(conn, user_id: @mate_id,
                                                    quest_id: other_quest,
                                                    snapshot: "not yours")
    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.create_workspace_grant!(conn, user: user, workspace: ws,
                                                        source_urn: other_source[:urn],
                                                        note: "n")
    end
    assert_match(/no source with urn/, error.message)
    assert_includes error.message, "owner-only",
                    "fk_resource_grants_source taught, never a 500"
    assert_empty conn[:resource_grants].to_a, "no row behind the refusal"

    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.create_workspace_grant!(conn, user: user, workspace: ws,
                                                        source_urn: source[:urn], note: "   ")
    end
    assert_includes error.message, "a note is required",
                    "the REQUIRED-note law (the mute's precedent class)"
    assert_empty conn[:resource_grants].where(source_id: source[:id]).to_a,
                 "no row behind the refusal"

    Kquest::Ui::OperatorWrite.create_workspace_grant!(conn, user: user, workspace: ws,
                                                      source_urn: source[:urn], note: "first")
    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.create_workspace_grant!(conn, user: user, workspace: ws,
                                                        source_urn: source[:urn],
                                                        note: "second")
    end
    assert_match(/already granted/, error.message,
                 "no schema unique on (source, grantee) — the DOOR keeps the ledger honest")
    assert_equal 1, conn[:resource_grants].where(source_id: source[:id]).count,
                 "the duplicate refusal never accumulates rows"
  end

  def test_create_public_grant_lands_is_public_and_teaches_source_note_duplicate
    source = mint_operator_source!
    grant = Kquest::Ui::OperatorWrite.create_public_grant!(conn, user: user,
                                                           source_urn: source[:urn],
                                                           note: "the public why")
    refute_nil grant
    assert_equal @tenancy[:user_id], grant.fetch(:owner_user_id)
    assert_equal source[:id], grant.fetch(:source_id)
    assert_equal true, grant.fetch(:is_public), "the global door"
    assert_nil grant.fetch(:grantee_user_id), "the exactly-one shape is the insert's own"
    assert_nil grant.fetch(:grantee_workspace_id)
    assert_equal "the public why", grant.fetch(:note)

    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.create_public_grant!(conn, user: user,
                                                     source_urn: "kb:src:nope123456",
                                                     note: "n")
    end
    assert_match(/no source with urn/, error.message)
    assert_includes error.message, "owner-only"

    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.create_public_grant!(conn, user: user,
                                                     source_urn: source[:urn], note: nil)
    end
    assert_includes error.message, "a note is required"

    error = assert_raises(Kquest::Engine::Error) do
      Kquest::Ui::OperatorWrite.create_public_grant!(conn, user: user,
                                                     source_urn: source[:urn],
                                                     note: "second")
    end
    assert_match(/already has a public grant/, error.message)
    assert_equal 1, conn[:resource_grants].where(source_id: source[:id]).count
  end

  def test_revoke_grant_deletes_the_row_the_i02_absence_law
    source = mint_operator_source!
    grant_id = conn[:resource_grants].insert(owner_user_id: @tenancy[:user_id],
                                             source_id: source[:id], is_public: true,
                                             note: "n")
    grant = conn[:resource_grants].where(id: grant_id).first
    assert_nil Kquest::Ui::OperatorWrite.revoke_grant!(conn, user: user, grant: grant)
    assert_empty conn[:resource_grants].where(id: grant_id),
                 "revocation IS row deletion — private = absence, the I02 law"
  end
end
