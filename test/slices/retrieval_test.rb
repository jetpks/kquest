# frozen_string_literal: true

require_relative "../test_helper"

# The retrieval slice: the model registry + job ledger + BOTH generated
# vector tables (the pgvector columns declared explicitly as their String
# wire form — rom-sql cannot infer them).
class SlicesRetrievalTest < Minitest::Test
  def conn
    @conn ||= Kquest::App["db.gateway"].connection
  end

  def slice
    @slice ||= Kquest::App.slices.to_a.find { |s| s.slice_name.to_s == "retrieval" }
  end

  def rom
    @rom ||= slice["db.rom"]
  end

  def test_slice_boots
    refute_nil slice
  end

  def test_pinned_relations_resolve_and_count
    %w[embedding_models embed_jobs emb_bge_m3_1024 emb_minilm_ab_384].each do |key|
      count = rom.relations[key].count
      assert count >= 0, "relation #{key} did not resolve"
    end
  end

  # The seeded D4 registry row is visible through the relation.
  def test_embedding_models_repo_reads_the_seeded_bge_m3_row
    found = slice["repos.embedding_models_repo"]
              .by_pk("92000000-0000-4000-8000-000000000001")
    refute_nil found, "the seeded bge-m3 registry row is missing"
    assert_equal "bge-m3", found.wire_name
    assert_equal 1024, found.dimensions
  end

  def test_embed_jobs_repo_round_trip
    user_id = SecureRandom.uuid
    conn[:users].insert(
      id: user_id, handle: "gh-retrieval-test", github_uid: "retrieval-test-uid",
      username: "retrieval-test", created_at: Time.now, updated_at: Time.now
    )
    job_id = SecureRandom.uuid
    conn[:embed_jobs].insert(
      id: job_id, user_id: user_id, kind: "fetch",
      state: "pending", idem_key: "test:retrieval-slice:fetch"
    )
    found = slice["repos.embed_jobs_repo"].by_pk(job_id)
    refute_nil found, "EmbedJobsRepo#by_pk did not find the row"
    assert_equal "fetch", found.kind
  ensure
    conn[:embed_jobs].where(id: job_id).delete
    conn[:users].where(id: user_id).delete
  end
end
