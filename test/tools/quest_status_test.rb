# frozen_string_literal: true

require_relative "texts_test"

# quest_status — the agent's self-orientation (the frozen answer shape; the
# three DERIVED budget lines vs the quests budget columns).
class QuestStatusTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/quest_status.md", __dir__)

  def setup
    mint
    @tool = build_tool("quest_status")
  end

  def test_answer_shape_byte_matched_with_derived_budget_lines
    # the phase display + writer segment
    conn[:phases].where(id: @session[:phase_id]).update(kind: "descent", round_no: 3, attempt_no: 1)
    # the derived web-call count (tool_calls rows, ok only)
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id, session_id: @session[:id],
                             seq: 1, tool: "web_search", args: "{}", result: "{}", ok: true)
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id, session_id: @session[:id],
                             seq: 2, tool: "web_search", args: "{}", result: "{}", ok: false,
                             error_class: "BUDGET-EXCEEDED")
    # the derived token/spend rollup
    conn[:usage_events].insert(user_id: @user_id, quest_id: @quest_id, phase_id: @session[:phase_id],
                               session_id: @session[:id], kind: "llm", model: "test-model",
                               input_tokens: 931_000, output_tokens: 0)

    produced = execute_tool(@tool)
    session_prefix = @session[:id].to_s[0, 4]
    expected = frozen_answer("quest_status")
      .sub("quest=active", "quest=active")
      .sub("phase=descent(3/1)", "phase=descent(3/1)")
      .sub(/writer=session\/\w+/, "writer=session/#{session_prefix}")
      .sub("web_calls=42/1400", "web_calls=1/16")
      .sub("tokens=931k/2.0M", "tokens=931k/1.0M")
      .sub("spend_usd=1.24/5.00", "spend_usd=0.00/1.00")
    assert_equal expected, produced
  end

  def test_refused_web_call_made_no_wire_call_and_does_not_count
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id, session_id: @session[:id],
                             seq: 1, tool: "web_fetch", args: "{}", result: "{}", ok: false,
                             error_class: "BUDGET-EXCEEDED")
    assert_includes execute_tool(@tool), "web_calls=0/16"
  end
end
