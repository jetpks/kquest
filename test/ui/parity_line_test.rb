# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/orchestrator_fixtures"

# The parity echo law (I05 §5 / I16 AC6): the UI composes through the SHARED
# formatter `Kquest::Tools::QuestStatus.line` — byte-equality against the
# frozen canonical fixture is by construction, never by copy.
class ParityLineTest < Minitest::Test
  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/quest_status.md", __dir__)

  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def canonical_line
    @canonical_line ||= File.read(FIXTURE).lines
                           .map(&:rstrip).find { |l| l.start_with?("quest_status:") }
  end

  # The frozen fixture's exact field values (I05 §5's canonical line).
  def frozen_fields
    {quest: "active", phase: "descent(3/1)", writer: "session/8f3a",
     web_used: 42, web_cap: 1400, tokens_used: 931_000, tokens_cap: 2_000_000,
     spend_used: BigDecimal("1.24"), spend_cap: BigDecimal("5.00")}
  end

  def test_composed_line_byte_equals_the_frozen_canonical_line
    assert_equal canonical_line, Kquest::Tools::QuestStatus.line(frozen_fields)
  end

  def test_nil_session_degrades_phase_and_writer_to_dash
    line = Kquest::Tools::QuestStatus.line(frozen_fields.merge(phase: nil, writer: nil))
    assert_includes line, "phase=- writer=-", "no session row: the degraded tokens"
    assert_includes line, "web_calls=42/1400", "the budget lines never depend on a session"
    assert_includes line, "tokens=931k/2.0M"
    assert_includes line, "spend_usd=1.24/5.00"
  end

  def test_live_mint_composes_the_same_shape_through_the_shared_formatter
    tenancy = OrchestratorFixtures.mint_tenancy(conn, topic: "parity echo")
    phase_id = conn[:phases].insert(user_id: tenancy[:user_id], quest_id: tenancy[:quest_id],
                                    kind: "descent", round_no: 3, attempt_no: 1)
    session_id = PipelineFixtures.mint_session(conn, user_id: tenancy[:user_id],
                                               quest_id: tenancy[:quest_id],
                                               phase_id: phase_id)
    conn[:tool_calls].insert(user_id: tenancy[:user_id], quest_id: tenancy[:quest_id],
                             session_id: session_id, seq: 1, tool: "web_search",
                             args: "{}", result: "{}", ok: true)
    conn[:usage_events].insert(user_id: tenancy[:user_id], quest_id: tenancy[:quest_id],
                               phase_id: phase_id, session_id: session_id, kind: "llm",
                               model: "test-model", input_tokens: 931_000, output_tokens: 0)

    f = Kquest::Queries::StatusSnapshot.new(conn: conn)
        .quest_fields(user_id: tenancy[:user_id], quest_id: tenancy[:quest_id],
                      session_id: session_id)
    produced = Kquest::Tools::QuestStatus.line(f)

    expected = canonical_line
               .sub(/writer=session\/\w+/, "writer=session/#{session_id.to_s[0, 4]}")
               .sub("web_calls=42/1400", "web_calls=1/16")
               .sub("tokens=931k/2.0M", "tokens=931k/1.0M")
               .sub("spend_usd=1.24/5.00", "spend_usd=0.00/1.00")
    assert_equal expected, produced
  ensure
    OrchestratorFixtures.cleanup(conn, user_id: tenancy[:user_id]) if tenancy
  end
end
