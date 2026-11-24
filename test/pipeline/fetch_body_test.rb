# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/pipeline_fixtures"

# The fixture-injected fetch body: content-addressed registration, dedup,
# and the minted-complete ledger row.
class FetchBodyTest < Minitest::Test
  def conn = @conn ||= Kquest::App["db.gateway"].connection

  def teardown
    PipelineFixtures.cleanup(conn, user_id: @user_id) if @user_id
  end

  # The I01 seed's s1 fixture bytes — the design corpus's own re-derivation
  # lands urn kb:src:G4QeEUXJeL through the pipeline's Base58 + CanonicalUrl.
  S1_CANONICAL = "https://fixture.example/definitions-note"
  S1_BODY = <<~S1.chomp
    The t-statistic is the ratio of an estimated coefficient to its standard error.
    Under the null hypothesis of a zero coefficient the t-statistic converges in distribution to the standard normal.
    A confidence interval for a coefficient is the estimate plus or minus the critical value times the standard error.
    Fixture text synthesized for the kquest I01 seed; it quotes no real source.
  S1

  def fetch_s1(quest_id:, url: S1_CANONICAL)
    Kquest::Pipeline::FetchBody.call(
      user_id: @user_id, url: url, title: "Fixture definitions note (synthetic)", role: "citable",
      snapshot_text: S1_BODY, raw_body: "raw-envelope:s1:#{S1_BODY}", quest_id: quest_id,
      phase_id: @phase_id, conn: conn
    )
  end

  def test_registration_with_design_urn_blob_read_back_membership_and_minted_complete_row
    tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = tenancy[:user_id]

    result = fetch_s1(quest_id: tenancy[:quest_id])
    assert_equal "kb:src:G4QeEUXJeL", result[:urn]
    assert_equal true, result[:created]

    source = conn[:sources].where(id: result[:source_id]).first
    assert_equal S1_CANONICAL, source[:canonical_url]
    assert_equal Digest::SHA256.hexdigest(S1_BODY), source[:snapshot_sha256].strip

    # Blob read-back through the uploader (location-addressed, Grounds
    # decision 6 — NOT the generated blob-key columns).
    location = Kquest::BlobUploader.location_for(:snapshot, user: @user_id, source_urn: result[:urn])
    read_back = Kquest::BlobUploader.uploaded_file(JSON.generate({"id" => location, "storage" => "store"}))
    assert_equal S1_BODY, read_back.read
    raw_job = conn[:embed_jobs].where(kind: "fetch", source_id: source[:id]).first
    raw_location = Kquest::BlobUploader.location_for(:raw, user: @user_id, fetch_id: raw_job[:id])
    assert_equal "raw-envelope:s1:#{S1_BODY}",
      Kquest::BlobUploader.uploaded_file(JSON.generate({"id" => raw_location, "storage" => "store"})).read

    # Membership registered for the requesting quest.
    assert conn[:quest_sources].where(quest_id: tenancy[:quest_id], source_id: result[:source_id]).first

    # The job row minted COMPLETE — with NO usage link (web-call budget is
    # the web ops' ledger, not token spend).
    job = conn[:embed_jobs].where(kind: "fetch", source_id: result[:source_id]).first
    refute_nil job
    assert_equal "complete", job[:state]
    assert_equal 1, job[:done_items]
    assert_equal "fetch:#{@user_id}:#{result[:urn]}", job[:idem_key]
    assert_nil job[:usage_event_id]
    assert_equal 0, conn[:usage_events].where(user_id: @user_id).count
  end

  def test_fetch_once_dedup_by_content_address_and_changed_page_refetches
    tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = tenancy[:user_id]
    other_quest = conn[:quests].insert(user_id: @user_id, topic: "Second fixture quest",
      web_call_budget: 8, token_budget: 100_000, spend_budget_usd: 1.0)

    first = fetch_s1(quest_id: tenancy[:quest_id])
    again = fetch_s1(quest_id: other_quest) # same bytes, DIFFERENT quest

    # Fetch-once per user: same source row; the second quest's membership
    # registers on the dedup path (one source serves many quests).
    assert_equal false, again[:created]
    assert_equal first[:source_id], again[:source_id]
    assert conn[:quest_sources].where(quest_id: other_quest, source_id: first[:source_id]).first
    assert_equal 1, conn[:sources].where(user_id: @user_id).count
    assert_equal 2, conn[:quest_sources].where(source_id: first[:source_id]).count

    # A changed page is a NEW content address → a new source row, not an
    # overwrite (D3 content-address identity).
    changed = fetch_s1(quest_id: tenancy[:quest_id], url: S1_CANONICAL) # same url...
    assert_equal false, changed[:created] # ...same bytes → dedup, not a refetch

    refetch = Kquest::Pipeline::FetchBody.call(
      user_id: @user_id, url: S1_CANONICAL, title: "Fixture definitions note (rev 2)", role: "citable",
      snapshot_text: "#{S1_BODY}\nAdded paragraph in revision two.", raw_body: "raw-envelope:s1:rev2",
      quest_id: tenancy[:quest_id], phase_id: tenancy[:phase_id], conn: conn
    )
    assert_equal true, refetch[:created]
    refute_equal first[:source_id], refetch[:source_id]
    refute_equal first[:urn], refetch[:urn]
    assert_equal 2, conn[:sources].where(user_id: @user_id).count
  end

  def test_tracking_param_strip_collapses_identity
    tenancy = PipelineFixtures.mint_tenancy(conn)
    @user_id = tenancy[:user_id]

    # The s2 demonstration: the url carries ?utm_source=newsletter; the
    # canonical form does not — both fetches collapse to ONE source.
    tracked = fetch_s1(quest_id: tenancy[:quest_id],
                       url: "#{S1_CANONICAL}?utm_source=newsletter")
    clean = fetch_s1(quest_id: tenancy[:quest_id], url: S1_CANONICAL)

    assert_equal false, clean[:created]
    assert_equal tracked[:source_id], clean[:source_id]
    assert_equal "https://fixture.example/definitions-note",
      conn[:sources].where(id: tracked[:source_id]).first[:canonical_url]
    assert_equal 1, conn[:sources].where(user_id: @user_id).count
  end
end
