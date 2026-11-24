# frozen_string_literal: true

require_relative "../test_helper"

# The BlobUploader contract (I11 Part 6 / I08 §7): memory-store round-trip in
# test env, kind-parameterized location generation under the three
# Shrine-written roots, JSON reconstitution via uploaded_file. Sources are
# FETCHED, not uploaded — this uploader has no HTTP surface at all.
class BlobUploaderTest < Minitest::Test
  def test_storages_configured_as_memory_in_test
    storages = Kquest::BlobUploader.storages
    assert storages.key?(:store), "storages missing :store"
    assert_equal "Shrine::Storage::Memory", storages[:store].class.name
  end

  def test_snapshot_location_is_user_scoped_by_source_urn
    location = Kquest::BlobUploader.location_for(
      :snapshot, user: "u-1", source_urn: "kb:src:abc123defG"
    )
    assert_equal "snapshots/u-1/kb:src:abc123defG", location
  end

  def test_raw_location_is_user_scoped_by_fetch_id
    location = Kquest::BlobUploader.location_for(
      :raw, user: "u-1", fetch_id: "f-77"
    )
    assert_equal "raw/u-1/f-77", location
  end

  def test_report_location_is_version_scoped
    location = Kquest::BlobUploader.location_for(
      :report, report_version_id: "rv-9"
    )
    assert_equal "reports/rv-9", location
  end

  def test_unknown_kind_is_refused
    assert_raises(ArgumentError) do
      Kquest::BlobUploader.location_for(:transcript, quest: "q")
    end
  end

  # The transcript root is documented as a constant (the append writer is
  # ENTRY 3's TranscriptLedger; no Shrine write path here).
  def test_transcripts_layout_constant
    assert_equal "transcripts/q-1/s-2/transcript.jsonl",
                 format(Kquest::BlobUploader::TRANSCRIPTS_LAYOUT, quest: "q-1", session: "s-2")
  end

  def test_store_round_trip_via_uploaded_file
    content = "snapshot bytes\nline two\n"
    data = Kquest::BlobUploader.store(
      StringIO.new(content), kind: :snapshot, user: "u-1", source_urn: "kb:src:abc123defG"
    )

    assert_kind_of String, data
    parsed = JSON.parse(data)
    assert_equal "store", parsed["storage"]
    assert_equal "snapshots/u-1/kb:src:abc123defG", parsed["id"]

    attachment = Kquest::BlobUploader.uploaded_file(data)
    assert_instance_of Kquest::BlobUploader::UploadedFile, attachment
    assert_equal content, attachment.open { |io| io.read }
  end
end
