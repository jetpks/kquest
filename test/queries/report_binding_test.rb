# frozen_string_literal: true

require_relative "../tools/texts_test"

# report_binding — I02 §9/B1, transcribed.
class ReportBindingQueryTest < Minitest::Test
  include ToolRig

  BODY = "cites the first staged source[^1] and the second[^2]."

  def setup
    mint
    conn[:phases].where(id: @session[:phase_id]).update(kind: "synthesis")
    @query = Kquest::Queries::ReportBinding.new(conn: conn)
    @s1 = mint_source(snapshot: "a", title: "First", added_at: Time.now - 60)
    @s2 = mint_source(snapshot: "b", title: "Second", added_at: Time.now - 30)
    @version = mint_version
  end

  def mint_version
    id = SecureRandom.uuid
    conn[:report_versions].insert(
      id: id, user_id: @user_id, quest_id: @quest_id, version_seq: 1,
      synthesis_phase_id: @session[:phase_id], created_session_id: @session[:id],
      model: "test-model", body_blob_key: "reports/#{id}/v1.md",
      body_sha256: "0" * 64, quest_fingerprint: "0" * 64
    )
    conn[:report_versions].where(id: id).first
  end

  # the frozen family property (AC4)
  def test_binding_determinism_byte_equal
    first = @query.bind(user_id: @user_id, quest_id: @quest_id, version_row: @version, body: BODY)
    second = @query.bind(user_id: @user_id, quest_id: @quest_id, version_row: @version, body: BODY)
    assert_equal first[:footnote_block], second[:footnote_block]
    assert_equal first[:citations].map(&:to_h), second[:citations].map(&:to_h)
  end

  def test_citation_index_is_the_staging_order
    index = @query.citation_index(user_id: @user_id, quest_id: @quest_id)
    assert_equal [@s1[:id], @s2[:id]], index.map { |r| r[:id] }
  end

  def test_footnote_block_is_the_frozen_line_format
    result = @query.bind(user_id: @user_id, quest_id: @quest_id, version_row: @version, body: BODY)
    lines = result[:footnote_block].split("\n")
    assert_equal 2, lines.size
    assert_match(/\A\[\^1\]: #{@s1[:urn]} — First, https:\/\/example\.test\/#{Regexp.escape(@s1[:urn])}, fetched \d{4}-\d{2}-\d{2}\z/, lines[0])
  end

  def test_ordinal_unbound_when_beyond_the_corpus
    result = assert_raises(Kquest::Engine::Error) do
      @query.bind(user_id: @user_id, quest_id: @quest_id, version_row: @version,
                  body: "beyond the corpus[^3].")
    end
    assert_includes result.message, "citation [^3] does not resolve"
  end
end
