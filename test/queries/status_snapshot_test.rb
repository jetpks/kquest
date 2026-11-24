# frozen_string_literal: true

require_relative "../tools/texts_test"

# status_snapshot — the §5 parity reads (T-GATE).
class StatusSnapshotQueryTest < Minitest::Test
  include ToolRig

  def setup
    mint
    @query = Kquest::Queries::StatusSnapshot.new(conn: conn)
  end

  # the frozen family property (AC4): the parity field sets — EXACTLY the §5
  # fields, no decorative additions
  def test_parity_field_sets
    fields = @query.status_fields(user_id: @user_id, quest_id: @quest_id)
    assert_equal %w[bare_claims claims decompose_remaining dual_arm_claims evidence
                    frontier_mass frontier_open unreferenced],
                 fields.keys.map(&:to_s).sort
    q = @query.quest_fields(user_id: @user_id, quest_id: @quest_id, session_id: @session[:id])
    assert_equal %w[phase quest spend_cap spend_used tokens_cap tokens_used web_cap web_used
                    writer],
                 q.keys.map(&:to_s).sort
  end

  def test_status_aggregates_over_the_law_views
    claim = PipelineFixtures.mint_claim(conn, user_id: @user_id, quest_id: @quest_id, seq: 1,
                                        text: "a bare claim")
    fields = @query.status_fields(user_id: @user_id, quest_id: @quest_id)
    assert_equal 1, fields[:claims]
    assert_equal 1, fields[:bare_claims], "over v_claim_closure, the same view any gate sweeps"

    conn[:claims].where(id: claim).update(terminal_type: "primary-empirical", terminal_basis: "b")
    fields = @query.status_fields(user_id: @user_id, quest_id: @quest_id)
    assert_equal 0, fields[:bare_claims]
    assert_equal 1, fields[:unreferenced], "terminal but unreferenced"
  end

  def test_budget_lines_are_derived_never_stored
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id, session_id: @session[:id],
                             seq: 1, tool: "web_search", args: "{}", result: "{}", ok: true)
    conn[:usage_events].insert(user_id: @user_id, quest_id: @quest_id, phase_id: @session[:phase_id],
                               session_id: @session[:id], kind: "llm", model: "test-model",
                               input_tokens: 1500, output_tokens: 0)
    q = @query.quest_fields(user_id: @user_id, quest_id: @quest_id, session_id: @session[:id])
    assert_equal 1, q[:web_used]
    assert_equal 16, q[:web_cap]
    assert_equal 1500, q[:tokens_used]
    assert_equal 1_000_000, q[:tokens_cap]
  end
end
