# frozen_string_literal: true

require_relative "texts_test"

# report_draft — structured sectioned authoring on the session's DRAFT
# version (the version chain per I02 §7).
class ReportDraftTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/report_draft.md", __dir__)

  def setup
    mint
    # report_versions FK: the version's synthesis phase must BE a synthesis
    # phase (the version chain per I02 §7)
    conn[:phases].where(id: @session[:phase_id]).update(kind: "synthesis")
    @tool = build_tool("report_draft")
  end

  def test_sections_accumulate_on_the_session_draft_version
    a = execute_tool(@tool, section: "findings/brinson-attribution", body: "the first section body")
    b = execute_tool(@tool, section: "findings/net-of-costs", body: "the second section body")

    version = conn[:report_versions].where(quest_id: @quest_id).first
    refute_nil version
    assert_equal 1, version[:version_seq]
    assert_equal @session[:id], version[:created_session_id]
    refute version[:standing]
    assert_includes a, "findings/brinson-attribution"
    assert_includes b, "findings/net-of-costs"
  end

  def test_section_too_large_refusal_byte_matched
    assert_refusal("report_draft", "section-too-large", slots: {cap: "capped at 20000 chars"},
                   planted: ["20000"]) do
      execute_tool(@tool, section: "findings/too-big", body: "x" * 20_001)
    end
  end

  def test_version_frozen_refusal_byte_matched
    execute_tool(@tool, section: "findings/one", body: "body")
    version = conn[:report_versions].where(quest_id: @quest_id).first
    conn[:report_versions].where(id: version[:id]).update(
      standing: true, bound_at: Time.now, binding_pass: "i02-9/i14"
    )

    assert_refusal("report_draft", "version-frozen", slots: {version: "version 1"},
                   planted: ["version 1"]) do
      execute_tool(@tool, version: "1", section: "findings/two", body: "body2")
    end
  end

  def test_body_sha256_pins_the_bytes
    execute_tool(@tool, section: "findings/one", body: "a pinned body")
    version = conn[:report_versions].where(quest_id: @quest_id).first
    require "digest"
    assert_equal Digest::SHA256.hexdigest("\n## findings/one\na pinned body"), version[:body_sha256]
  end
end
