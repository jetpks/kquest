# frozen_string_literal: true

require_relative "../test_helper"
require "fast/completions"
require_relative "../support/orchestrator_fixtures"
require_relative "../../lib/kquest/orchestrator/briefing_contract"
require_relative "../../lib/kquest/engine/transcript_ledger"

# The BriefingContract (I18 Spec Part 1.4): the PhaseContract's four-part
# assembly bound to the OPERATOR session's binding decompose round-1 phase —
# the seeded `phase_task_text.briefing` task text (missing row = the LOUD
# assembly refusal), decompose-targeting overlays, the status/gate parity
# surface incl. `agenda_staged` + the three budget lines, boundary state =
# staged agenda + current questions + topic; terminal? = the PhaseContract's
# exact shape; max_turns = phase.max_turns || 64; the conversation rebuilt
# from durable state (L7 — the ledger blob's operator/final/tool_result
# lines). All keyless.
class BriefingContractTest < Minitest::Test
  TASK_TEXT = "Converse with the operator to decompose the top-level question."

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    @user_id = @tenancy[:user_id]
    @quest_id = @tenancy[:quest_id]
    @phase_id = conn[:phases].insert(user_id: @user_id, quest_id: @quest_id, kind: "decompose",
                                     round_no: 1, attempt_no: 1, state: "pending")
    @session_id = conn[:sessions].insert(user_id: @user_id, quest_id: @quest_id,
                                         phase_id: @phase_id, mode: "interactive",
                                         driver: "operator", model: "operator")
    set_task_text(TASK_TEXT)
  end

  def teardown
    OrchestratorFixtures.cleanup(conn, user_id: @user_id)
  end

  def set_task_text(text)
    conn[:tool_config].where(key: "phase_task_text.briefing").delete
    conn[:tool_config].insert(key: "phase_task_text.briefing", text_value: text,
                              provenance: "I18 test-minted config data")
  end

  def session_hash
    {id: @session_id, user_id: @user_id, quest_id: @quest_id, phase_id: @phase_id,
     model: "operator", driver: "operator"}
  end

  def config(process: {}, model_config: {})
    {engine: Kquest::Engine::DEFAULT_CONFIG.transform_values { |v| {value: v, mode: "advisory"} },
     tools: Kquest::Tools.config(conn),
     process: process,
     model_config: model_config,
     stop_rules: conn[:stop_rules].order(:rule_id).to_a}
  end

  def ledger
    @ledger ||= Kquest::Engine::TranscriptLedger.new(conn: conn, session: session_hash)
  end

  def contract(process: {})
    Kquest::Orchestrator::BriefingContract.new(
      conn: conn, quest: conn[:quests].where(id: @quest_id).first,
      phase: conn[:phases].where(id: @phase_id).first,
      session: session_hash, config: config(process: process), ledger: ledger
    )
  end

  def stage_agenda(title)
    OrchestratorFixtures.mint_source(conn, user_id: @user_id, quest_id: @quest_id,
                                     snapshot: "agenda bytes for #{title}", role: "agenda",
                                     title: title)
  end

  # ── part 1: the seeded task text ──────────────────────────────────────

  def test_task_text_is_the_seeded_phase_task_text_briefing_row
    instructions = contract.assemble_context(0).fetch(:instructions)
    assert_includes instructions, "TASK: #{TASK_TEXT}"
  end

  def test_missing_task_row_is_the_loud_assembly_refusal
    conn[:tool_config].where(key: "phase_task_text.briefing").delete

    error = assert_raises(Kquest::Engine::Error) { contract.assemble_context(0) }
    assert_includes error.message, "phase_task_text.briefing"
    assert_includes error.message, "seed the row"
  end

  # ── part 2: decompose-targeting overlays ─────────────────────────────

  def test_overlays_targeting_decompose_apply
    overlays = [{"name" => "AGENDA-ONLY", "phase_kinds" => ["decompose"],
                 "text" => "never anchor, never cite"},
                {"name" => "OTHER", "phase_kinds" => ["descent"], "text" => "not mine"}]
    instructions = contract(process: {"overlays" => overlays}).assemble_context(0)
                                                               .fetch(:instructions)
    assert_includes instructions, "OVERLAY AGENDA-ONLY: never anchor, never cite"
    refute_includes instructions, "not mine"
  end

  # ── part 3: the status/gate parity surface ───────────────────────────

  def test_status_surface_carries_agenda_staged_and_the_three_budget_lines
    stage_agenda("the primer")
    instructions = contract.assemble_context(0).fetch(:instructions)

    assert_includes instructions, "agenda_staged=true"
    assert_match(/STATUS: .*\bagenda_staged=true\b/, instructions)
    assert_match(/QUEST_STATUS: quest=\w+ .*web_used=\d+ web_cap=\d+/, instructions,
                 "the web-call budget line (the extended count)")
    assert_match(/tokens_used=\d+ tokens_cap=\d+/, instructions, "the token budget line")
    assert_match(/spend_used=\S+ spend_cap=\S+/, instructions, "the spend budget line")
  end

  def test_agenda_staged_is_false_before_anything_is_staged
    instructions = contract.assemble_context(0).fetch(:instructions)
    assert_includes instructions, "agenda_staged=false"
  end

  # ── part 4: boundary state ───────────────────────────────────────────

  def test_boundary_state_carries_the_staged_agenda_questions_and_topic
    source = stage_agenda("The decay primer")
    conn[:phases].where(id: @phase_id)
                 .update(result: Sequel.lit("?::jsonb",
                                           JSON.generate({"topic_questions" => ["Q one?", "Q two?"]})))
    conn[:quests].where(id: @quest_id).update(topic: "the agreed topic")
    conn[:tool_config].where(key: "ui.listing_cap.briefing").delete
    conn[:tool_config].insert(key: "ui.listing_cap.briefing", num_value: 30,
                              provenance: "test-minted cap row")

    instructions = contract.assemble_context(0).fetch(:instructions)

    assert_includes instructions, "AGENDA STAGED: #{source.fetch(:urn)} \"The decay primer\""
    assert_includes instructions, "TOPIC QUESTIONS: Q one? | Q two?"
    assert_includes instructions, "TOPIC: the agreed topic"
  end

  def test_boundary_state_honest_when_nothing_staged_yet
    instructions = contract.assemble_context(0).fetch(:instructions)
    assert_includes instructions, "AGENDA STAGED: none yet"
    assert_includes instructions, "TOPIC QUESTIONS: none recorded yet"
  end

  # ── terminal? / max_turns (the PhaseContract's exact shapes) ─────────

  def test_terminal_is_content_bearing_text_only_completion_at_turn_one_or_later
    chat = Fast::Completions::Chat.new(client: Object.new, model: Object.new)
    assert_equal false, contract.terminal?(turn: 0, chat: chat), "turn 0 is never terminal"
    chat.add_message(Fast::Completions::Message.user("op"))
    chat.add_message(Fast::Completions::Message.assistant([{type: :text, text: "the reply"}]))
    assert_equal true, contract.terminal?(turn: 1, chat: chat)

    tool_chat = Fast::Completions::Chat.new(client: Object.new, model: Object.new)
    tool_chat.add_message(Fast::Completions::Message.user("op"))
    tool_chat.add_message(Fast::Completions::Message.assistant(
                            [{type: :tool_call, id: "t1", name: "agenda_stage", arguments: {}}]
                          ))
    assert_equal false, contract.terminal?(turn: 1, chat: tool_chat), "a tool_call stop never is"

    empty_chat = Fast::Completions::Chat.new(client: Object.new, model: Object.new)
    empty_chat.add_message(Fast::Completions::Message.user("op"))
    empty_chat.add_message(Fast::Completions::Message.assistant([{type: :text, text: "  "}]))
    assert_equal false, contract.terminal?(turn: 1, chat: empty_chat), "an EMPTY completion never is"
  end

  def test_max_turns_is_the_phase_max_turns_key_else_64
    assert_equal 64, contract.max_turns
    assert_equal 64, contract(process: {"phase.max_turns" => 64.0}).max_turns
    assert_equal 12, contract(process: {"phase.max_turns" => 12}).max_turns
  end

  # ── the durable conversation (L7) ────────────────────────────────────

  def test_conversation_is_rebuilt_from_the_ledger_blob
    Sync do
      ledger.append_operator!(body: "first operator turn")
      ledger.record_tool_result!(tool: "agenda_stage", args: {url: "https://x"},
                                 content: "agenda_stage: staged …", is_error: false)
      ledger.append_turn(
        final: Fast::Completions::Message.assistant(
          [{type: :text, text: "I staged the primer."},
           {type: :tool_call, id: "call-1", name: "agenda_stage",
            arguments: {url: "https://x"}}]
        ), turn: 0
      )
      ledger.append_operator!(body: "now write the questions")
      ledger.append_turn(
        final: Fast::Completions::Message.assistant([{type: :text, text: "Done — recorded."}]),
        turn: 1
      )
    end

    messages = contract.assemble_context(0).fetch(:messages)

    assert_equal 5, messages.size, "operator + assistant(+tool result) + operator + assistant"
    assert_equal :user, messages[0].role
    assert_equal "first operator turn", messages[0].content
    assert_equal :assistant, messages[1].role
    assert_equal :tool_result, messages[2].role
    assert_equal "call-1", messages[2].tool_call_id, "the tool_result pairs the assistant's id"
    assert_equal "agenda_stage", messages[2].tool_name
    assert_equal "agenda_stage: staged …", messages[2].content
    assert_equal :user, messages[3].role
    assert_equal "now write the questions", messages[3].content, "the newest operator line IS the new message"
    assert_equal :assistant, messages[4].role
    assert_equal "Done — recorded.", messages[4].content[0][:text]
  end

  def test_conversation_is_empty_before_the_first_turn
    assert_empty contract.assemble_context(0).fetch(:messages)
  end

  def test_salvage_and_delta_lines_never_enter_the_rebuilt_history
    partial = Fast::Completions::Message.assistant([{type: :text, text: "partial before the abort"}])
    Sync do
      ledger.observe(Fast::Completions::Event.new(type: :text_delta, delta: "partial", partial: partial))
      ledger.observe(Fast::Completions::Event.new(type: :error, partial: partial))
      ledger.flush_salvage!
      ledger.append_operator!(body: "go on")
      ledger.append_turn(
        final: Fast::Completions::Message.assistant([{type: :text, text: "recovered"}]),
        turn: 0
      )
    end

    messages = contract.assemble_context(0).fetch(:messages)
    assert_equal 2, messages.size, "salvage + delta lines are audit-only, never live history"
    assert_equal %i[user assistant], messages.map(&:role)
  end
end
