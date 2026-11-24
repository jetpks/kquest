# auto_register: false
# frozen_string_literal: true

require "shrine"
require "shrine/storage/file_system"
require "shrine/storage/memory"

# Storages are configured at class load (not via a provider) so Hanami.env? is
# the single switch: in-memory in test (no disk, no cleanup), file-system in
# dev/prod. Mirrors app/attachment_uploader.rb; this file IS the storage
# configuration point (R-078/D8): filesystem -> S3-class later = swap here.
if Hanami.env?(:test)
  Shrine.storages = {
    cache: Shrine::Storage::Memory.new,
    store: Shrine::Storage::Memory.new
  }
else
  # Resolve from __dir__ so the path is cwd-invariant (mirrors config/providers/vite.rb).
  # __dir__ = <app root>/app → parent = <app root>
  root = Pathname(__dir__).parent
  Shrine.storages = {
    cache: Shrine::Storage::FileSystem.new(root.join("storage", "cache").to_s),
    store: Shrine::Storage::FileSystem.new(root.join("storage", "store").to_s)
  }
end

module Kquest
  # The corpus blob uploader (I08 §7). Sources are FETCHED, not uploaded: the
  # only ingestion door is the fetch path (ENTRY 3's web_fetch tool), which
  # writes through this class — NO route, action, or page accepts a file.
  #
  # store(io, kind:, **ids) → the JSON string a text column carries;
  # `uploaded_file` reconstitutes it. Locations are kind-parameterized under
  # the four storage roots (I08 §7's layout, one name per concept):
  #
  #   kind: :snapshot  → snapshots/<user>/<source-urn>   (the canonical
  #                      anchoring target, byte-pinned to snapshot_char_count)
  #   kind: :raw       → raw/<user>/<fetch-id>           (the raw response,
  #                      provenance)
  #   kind: :report    → reports/<report-version-id>     (D8's third blob class)
  #
  # Transcripts are APPEND-MODE files under the same store — never written
  # here (no Shrine write path; appending is ENTRY 3's TranscriptLedger):
  #
  #   TRANSCRIPTS_LAYOUT: transcripts/<quest>/<session>/transcript.jsonl
  #
  class BlobUploader < Shrine
    # The transcript layout constant — the append writer (ENTRY 3) builds
    # locations as format(TRANSCRIPTS_LAYOUT, ...). Documented, not written.
    TRANSCRIPTS_LAYOUT = "transcripts/%<quest>s/%<session>s/transcript.jsonl"

    def self.store(io, kind:, **ids)
      location = location_for(kind, **ids)
      upload(io, :store, location: location).to_json
    end

    # The kind → location map, kept separate so the layout is testable
    # without a wire call.
    def self.location_for(kind, **ids)
      case kind
      when :snapshot then "snapshots/#{ids.fetch(:user)}/#{ids.fetch(:source_urn)}"
      when :raw      then "raw/#{ids.fetch(:user)}/#{ids.fetch(:fetch_id)}"
      when :report   then "reports/#{ids.fetch(:report_version_id)}"
      else raise ArgumentError, "unknown blob kind: #{kind.inspect} " \
                                "(expected :snapshot, :raw, or :report)"
      end
    end
  end
end
