# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/pipeline_fixtures"

# The chunk body: the quest's staged sources, per-chunk REPLACE + durable
# cursor, no usage row.
class ChunkBodyTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def teardown
    PipelineFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  def paragraph(word, size = 300)
    (([word] * (size / (word.length + 1))).join(" ") + " ") * 1 + "\n"
  end

  def register_source(quest_id:, urn_tag:, paragraphs:, role: "citable")
    Kquest::Pipeline::FetchBody.call(
      user_id: @user_id, url: "https://fixture.example/#{urn_tag}", title: "Chunk fixture #{urn_tag}",
      role: role, snapshot_text: paragraphs.join, raw_body: "raw:#{urn_tag}",
      quest_id: quest_id, conn: conn
    )
  end

  def mint_chunk_job(strategy_id, quest_id)
    PipelineFixtures.mint_embed_job(conn, user_id: @user_id, quest_id: quest_id,
      phase_id: @phase_id, kind: "chunk", strategy_id: strategy_id,
      idem_key: "chunk:#{strategy_id}:quest:#{quest_id}")
  end

  def test_chunks_the_quest_sources_and_completes
    tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = tenancy[:user_id]
    @phase_id = tenancy[:phase_id]
    strategy_id = PipelineFixtures.mint_strategy(conn, name: "para-800")
    snapshot = ["alpha paragraph one.", "alpha paragraph two.", "beta paragraph three."]
      .map { |p| (p + " " + "filler " * 60 + "\n") }
    s1 = register_source(quest_id: tenancy[:quest_id], urn_tag: "chunk-one", paragraphs: snapshot)
    s2 = register_source(quest_id: tenancy[:quest_id], urn_tag: "chunk-agenda",
                         paragraphs: ["agenda filler " * 30 + "\n"], role: "agenda")

    job_id = mint_chunk_job(strategy_id, tenancy[:quest_id])
    Kquest::Pipeline::ChunkBody.new(conn: conn).run(conn[:embed_jobs].where(id: job_id).first)

    rows = conn[:chunks].where(strategy_id: strategy_id).order(:source_id, :ordinal).all
    expected_snapshot_chars = conn[:sources].where(id: s1[:source_id]).first[:snapshot_char_count]
    # Every chunk: verbatim offsets coherent, snapshot_char_count mirrors the
    # source, anchorable mirrors the source's role (citable → true).
    rows.each do |c|
      assert_equal c[:text].length, c[:char_end] - c[:char_start]
      assert_equal expected_snapshot_chars, c[:snapshot_char_count] if c[:source_id] == s1[:source_id]
      assert_equal c[:source_id] == s1[:source_id], c[:source_anchorable] # s2 is agenda → false
    end
    assert_operator rows.count, :>=, 3, "multi-paragraph source yields several chunks"
    assert_equal "complete", conn[:embed_jobs].where(id: job_id).first[:state]
    assert_equal rows.count, conn[:embed_jobs].where(id: job_id).first[:done_items]
    assert_equal 0, conn[:usage_events].where(user_id: @user_id).count # no usage row
  end

  def test_resume_from_cursor_replaces_without_duplicates
    tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = tenancy[:user_id]
    @phase_id = tenancy[:phase_id]
    strategy_id = PipelineFixtures.mint_strategy(conn, name: "para-800")
    snapshot = ["p1.", "p2.", "p3.", "p4."].map { |p| (p + " " + "filler " * 60 + "\n") }
    register_source(quest_id: tenancy[:quest_id], urn_tag: "resume-one", paragraphs: snapshot)

    job_id = mint_chunk_job(strategy_id, tenancy[:quest_id])
    body = Kquest::Pipeline::ChunkBody.new(conn: conn)
    body.run(conn[:embed_jobs].where(id: job_id).first)
    expected = conn[:chunks].where(strategy_id: strategy_id).order(:ordinal).select_map(:text)
    assert_operator expected.size, :>=, 3

    # Simulate the kill: cursor rewound to k, the not-yet-written tail
    # removed, the row back to running.
    k = expected.size - 2
    conn[:chunks].where(strategy_id: strategy_id).where { ordinal > k }.delete
    conn[:embed_jobs].where(id: job_id).update(state: "running", done_items: k, ended_at: nil)

    body.run(conn[:embed_jobs].where(id: job_id).first)

    rows = conn[:chunks].where(strategy_id: strategy_id).order(:ordinal).all
    assert_equal expected.size, rows.size, "resume REPLACES, never duplicates"
    assert_equal expected, rows.map { |r| r[:text] }
    assert_equal expected.size, rows.map { |r| r[:ordinal] }.uniq.size
    row = conn[:embed_jobs].where(id: job_id).first
    assert_equal "complete", row[:state]
    assert_equal expected.size, row[:done_items]
    assert_nil conn[:embed_jobs].where(id: job_id).first[:usage_event_id]
  end
end
