# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/orchestrator_fixtures"
require "json"

# The briefing chat's transcript READER (I18 Spec Part 2.4 / AC13), unit
# test: the ledger blob parsed through the ledger's OWN sink seam
# (`TranscriptLedger.build_sink` stubbed over an injected MemorySink — the
# I13 pattern), tail-capped by the seeded `ui.listing_cap.briefing_transcript`
# row with the honest omitted count, mapping the landed ledger line types
# (operator/final/tool_call_start/tool_result/salvage — the shapes the
# worker lane's exchange lands, per test/integration/briefing_exchange_test.rb)
# to page lines. PH0-CU-4 is the mapping law.
class BriefingTranscriptTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def setup
    OrchestratorFixtures.sweep_all(conn)
    @tenancy = OrchestratorFixtures.mint_tenancy(conn)
    # The seeds re-heal at the next prepare, but other suites' teardowns wipe
    # tool_config (the config-table cleanup is global) — seed the row the
    # reader reads (the suite's random order makes this load-bearing).
    seed_cap_row(200)
    @sink = Kquest::Engine::TranscriptLedger::MemorySink.new
    Kquest::Engine::TranscriptLedger.singleton_class.alias_method(:i18cu_original_build_sink,
                                                                  :build_sink)
    sink = @sink
    Kquest::Engine::TranscriptLedger.singleton_class.define_method(:build_sink) { sink }
  end

  def teardown
    Kquest::Engine::TranscriptLedger.singleton_class.alias_method(:build_sink,
                                                                  :i18cu_original_build_sink)
    Kquest::Engine::TranscriptLedger.singleton_class.remove_method(:i18cu_original_build_sink)
    OrchestratorFixtures.cleanup(conn, user_id: @tenancy[:user_id])
  end

  def session
    {id: @tenancy[:quest_id], user_id: @tenancy[:user_id], quest_id: @tenancy[:quest_id],
     phase_id: nil, model: "operator"}
  end

  def blob_location
    Kquest::BlobUploader.location_for(:transcript, session_id: session.fetch(:id))
  end

  def seed_cap_row(cap)
    conn[:tool_config].where(key: "ui.listing_cap.briefing_transcript").delete
    conn[:tool_config].insert(key: "ui.listing_cap.briefing_transcript", num_value: cap,
                              text_value: nil, provenance: "test data (the seeds re-heal)")
  end

  def append(lines)
    lines.each { |line| @sink.append(blob_location, "#{JSON.generate(line)}\n") }
  end

  def test_an_empty_transcript_is_empty_lines_and_zero_omitted
    assert_equal({lines: [], omitted: 0}, Kquest::Ui::BriefingTranscript.for_session(conn, session))
  end

  def test_the_landed_ledger_lines_map_to_the_four_page_line_kinds
    append([
      {type: "operator", body: "search for the decay primer"},
      {type: "text_delta", text: "search"},
      {type: "tool_call_start", tool_call: {id: "ix1", name: "web_search",
                                            arguments: {query: "decay"}}},
      {type: "tool_call_end", tool_call: {id: "ix1", name: "web_search"}},
      {type: "tool_result", tool: "web_search", args: {query: "decay"},
       content: "3 results", is_error: false},
      {type: "final", turn: 1, stop_reason: nil,
       message: {content: [{type: "text", text: "Staged the primer."}],
                 model: "briefing-model", provider: "briefing-provider"}},
      {type: "salvage", message: {content: [{type: "text", text: "partial"}]}}
    ])
    out = Kquest::Ui::BriefingTranscript.for_session(conn, session)
    assert_equal 0, out[:omitted]
    assert_equal [
      {kind: "operator", body: "search for the decay primer"},
      {kind: "tool_call", tool: "web_search", excerpt: "{\"query\":\"decay\"}"},
      {kind: "tool_result", tool: "web_search", excerpt: "3 results", is_error: false},
      {kind: "final", body: "Staged the primer."},
      {kind: "salvage", body: "{\"content\":[{\"type\":\"text\",\"text\":\"partial\"}]}",
      marked: true}
    ], out[:lines],
                 "deltas and the tool_call_end echo render nothing; the four frozen kinds carry the page"
  end

  def test_a_tool_call_only_final_renders_nothing_via_final_its_calls_carry_the_page
    append([
      {type: "tool_call_start", tool_call: {id: "ix2", name: "agenda_stage",
                                            arguments: {url: "https://example.test/a"}}},
      {type: "final", turn: 1, stop_reason: nil,
       message: {content: [{type: "tool_call", id: "ix2", name: "agenda_stage",
                            arguments: {url: "https://example.test/a"}}]}}
    ])
    out = Kquest::Ui::BriefingTranscript.for_session(conn, session)
    assert_equal [{kind: "tool_call", tool: "agenda_stage",
                   excerpt: "{\"url\":\"https://example.test/a\"}"}], out[:lines]
  end

  def test_the_tail_cap_keeps_the_last_lines_with_the_honest_omitted_count
    append([
      {type: "operator", body: "one"}, {type: "operator", body: "two"},
      {type: "operator", body: "three"}, {type: "operator", body: "four"}
    ])
    out = Kquest::Ui::BriefingTranscript.for_session(conn, session, cap: 2)
    assert_equal %w[three four], out[:lines].map { |l| l[:body] }
    assert_equal 2, out[:omitted], "the omitted count is honest (never silent truncation)"
  end

  def test_the_cap_default_is_the_seeded_listing_cap_row
    seed_cap_row(1)
    append([{type: "operator", body: "one"}, {type: "operator", body: "two"}])
    out = Kquest::Ui::BriefingTranscript.for_session(conn, session)
    assert_equal %w[two], out[:lines].map { |l| l[:body] }
    assert_equal 1, out[:omitted], "config is the only cap source — the seeded row, no literal"
  end
  def test_a_torn_trailing_line_never_renders
    @sink.append(blob_location, "#{JSON.generate({type: "operator", body: "whole"})}\n{\"typ")
    out = Kquest::Ui::BriefingTranscript.for_session(conn, session)
    assert_equal [{kind: "operator", body: "whole"}], out[:lines]
    assert_equal 0, out[:omitted]
  end
end
