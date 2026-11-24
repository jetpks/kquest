# frozen_string_literal: true

require_relative "texts_test"
require "stringio"

# report_bind — the deterministic finalization pass (I02 §9, transcribed):
# citation index, ordinal extraction, binding rows, footnote block, hash
# scan, standing flip — ONE transaction; same inputs = byte-equal output.
class ReportBindTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/report_bind.md", __dir__)

  def setup
    mint
    conn[:phases].where(id: @session[:phase_id]).update(kind: "synthesis")
    @tool = build_tool("report_draft")
  end

  def draft_with_body(body)
    execute_tool(@tool, section: "findings/one", body: body)
    conn[:report_versions].where(quest_id: @quest_id).first
  end

  def test_bind_flips_standing_and_binds_ordinals
    draft_with_body("cites the first staged source[^1] and the second[^2].")
    s1 = mint_source(snapshot: "a", title: "First", added_at: Time.now - 60)
    s2 = mint_source(snapshot: "b", title: "Second", added_at: Time.now - 30)

    bind = build_tool("report_bind")
    answer = execute_tool(bind)

    version = conn[:report_versions].where(quest_id: @quest_id).first
    assert version[:standing]
    refute_nil version[:bound_at]
    citations = conn[:report_citations].where(report_version_id: version[:id]).to_a
    assert_equal [1, 2], citations.map { |c| c[:ordinal] }.sort
    assert_equal s1[:id], citations.find { |c| c[:ordinal] == 1 }[:source_id]
    assert_match(/\Areport_bind: version 1 bound — citations=2 ordinals dense footnote block rendered standing=true\z/,
                 answer)
  end

  def test_binding_determinism_byte_equal
    body = "cites the first staged source[^1]."
    draft_with_body(body)
    mint_source(snapshot: "a", title: "Deterministic", added_at: Time.now - 60)
    execute_tool(build_tool("report_bind"))

    # re-running the PASS over the same body + corpus is byte-equal
    # (uq_report_citations_ordinal keeps the ROWS unique; the RENDER is pure)
    version = conn[:report_versions].where(quest_id: @quest_id).first
    binder = Kquest::Queries::ReportBinding.new(conn: conn)
    first = binder.bind(user_id: @user_id, quest_id: @quest_id, version_row: version, body: body)
    second = binder.bind(user_id: @user_id, quest_id: @quest_id, version_row: version, body: body)
    assert_equal first[:footnote_block], second[:footnote_block]
    assert_equal first[:citations].map(&:to_h), second[:citations].map(&:to_h)
  end

  def test_ordinal_unbound_refusal_byte_matched
    draft_with_body("cites beyond the corpus[^3].")
    mint_source(snapshot: "a", added_at: Time.now - 60)

    assert_refusal("report_bind", "ordinal-unbound",
                   slots: {ordinal: "[^3]", corpus: "holds 1 sources (ordinals 1..1)",
                           imports: "holds 0 more"},
                   planted: ["[^3]", "1 sources"]) do
      execute_tool(build_tool("report_bind"))
    end
  end

  def test_import_unmarked_refusal_byte_matched
    draft_with_body("cites out of corpus[^2].")
    mint_source(snapshot: "a", added_at: Time.now - 60)
    # the cited ordinal exists in the user's tenancy but OUTSIDE this quest's
    # corpus — the manifest is the only legal route (never silent)
    require "digest"
    other_quest = conn[:quests].insert(user_id: @user_id, topic: "another fixture quest",
                                       web_call_budget: 1, token_budget: 1, spend_budget_usd: 1.0)
    urn = "kb:src:" + Kquest::Pipeline::Base58.encode(SecureRandom.bytes(12))[0, 10]
    sha = Digest::SHA256.hexdigest("b")
    source_id = conn[:sources].insert(
      user_id: @user_id, url: "https://example.test/#{urn}", canonical_url: "https://example.test/#{urn}",
      urn: urn, title: "Out-of-corpus source", role: "citable", fetched_at: Time.now,
      snapshot_sha256: sha, raw_sha256: sha, snapshot_char_count: 1
    )
    conn[:quest_sources].insert(quest_id: other_quest, source_id: source_id, user_id: @user_id)

    assert_refusal("report_bind", "import-unmarked", slots: {ordinal: "[^2]"}, planted: ["[^2]"]) do
      execute_tool(build_tool("report_bind"))
    end
  end

  def test_hash_transcription_refusal_byte_matched
    draft_with_body("the body transcribes a hash kb:src:AAAAAAAAA1 inline")

    assert_refusal("report_bind", "hash-transcription", slots: {}, planted: []) do
      execute_tool(build_tool("report_bind"))
    end
  end
end
