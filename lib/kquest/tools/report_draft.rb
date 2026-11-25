# frozen_string_literal: true

require "digest"
require "securerandom"
require "stringio"

module Kquest
  module Tools
    # Structured sectioned authoring (I05 §2 / I02 §7) on the session's DRAFT
    # version: a section key plus a body with inline citation ordinals `[^n]`
    # only (the model never transcribes hashes); bodies ride the `:report`
    # blob kind with `body_sha256` pinned. Bound (standing) versions are
    # frozen — a rework is a NEW draft version.
    class ReportDraft < Base
      tool_name "report_draft"

      parameters do
        {"type" => "object",
         "properties" => {"version" => {"type" => "string"},
                          "section" => {"type" => "string"},
                          "body" => {"type" => "string"}},
         "required" => %w[section body]}
      end

      def mutates? = true

      def execute(**args)
        # An EXPLICIT target that is already bound refuses (the frozen class):
        # bound versions never change — a rework is a NEW draft version.
        if args[:version] && args[:version] != "draft"
          target = conn[:report_versions].where(quest_id: quest_id,
                                                version_seq: args[:version].to_i).first
          refuse_bound(target[:version_seq].to_s) if target&.fetch(:standing)
        end

        version = draft_version(create: !args.key?(:version) || args[:version] == "draft")
        refuse_bound(version[:version_seq].to_s) if version&.fetch(:standing)

        body = args[:body].to_s
        cap = cfg("tools.cap_report_section_chars")
        if body.length > cap
          refuse("report_draft", "section-too-large", cap: "capped at #{cap} chars")
        end

        # Sections accumulate on the draft's body blob: existing body + the
        # new section (a markdown section keyed by its section path).
        existing = read_body(version)
        merged = existing.empty? ? section_text(args[:section], body) : "#{existing}\n#{section_text(args[:section], body)}"
        sha = Digest::SHA256.hexdigest(merged)
        Kquest::BlobUploader.store(StringIO.new(merged), kind: :report,
                                                          report_version_id: version.fetch(:id))
        conn[:report_versions].where(id: version.fetch(:id)).update(body_sha256: sha)
        _ = existing

        "section #{args[:section]} written (#{body.length} chars, body_sha256 #{sha[0, 12]}…)"
      end

      private

      def section_text(section, body)
        "\n## #{section}\n#{body}"
      end

      # The session's DRAFT version (the version chain per I02 §7): the
      # unbound version this session created, else a new one.
      def draft_version(create:)
        row = conn[:report_versions]
              .where(quest_id: quest_id, created_session_id: session.fetch(:id))
              .where(bound_at: nil)
              .order(Sequel.desc(:version_seq)).first
        return row if row
        return nil unless create

        # The I17 MINOR (I20 Part 6): a non-synthesis BINDING phase would hit
        # fk_report_versions_phase (composite → phases.kind) as a 500 — the
        # precondition is taught AT THE TOOL, before ANY write (L5).
        phase = conn[:phases].where(id: phase_id).first
        if phase && phase.fetch(:kind) != "synthesis"
          refuse("report_draft", "phase-not-synthesis",
                 phase: "#{phase.fetch(:kind)}(#{phase.fetch(:round_no)}/" \
                        "#{phase.fetch(:attempt_no)})")
        end

        seq = (conn[:report_versions].where(quest_id: quest_id).max(:version_seq) || 0) + 1
        fingerprint = conn[:v_quest_graph_fingerprint].where(quest_id: quest_id).get(:graph_fingerprint)
        id = SecureRandom.uuid
        conn[:report_versions].insert(
          id: id,
          user_id: user_id, quest_id: quest_id, version_seq: seq,
          synthesis_phase_id: phase_id, created_session_id: session.fetch(:id),
          model: session.fetch(:model),
          body_blob_key: "reports/#{id}/v#{seq}.md",
          body_sha256: Digest::SHA256.hexdigest(""),
          quest_fingerprint: fingerprint
        )
        conn[:report_versions].where(id: id).first
      end

      def refuse_bound(version)
        refuse("report_draft", "version-frozen", version: "version #{version}")
      end

      def read_body(version)
        # The blob is STORE-located (the uploader's :report layout); the
        # body_blob_key column carries the CHECK-law bookkeeping form.
        location = Kquest::BlobUploader.location_for(:report,
                                                     report_version_id: version.fetch(:id))
        Kquest::BlobUploader.uploaded_file(JSON.generate({"id" => location, "storage" => "store"})).read
      rescue StandardError
        ""
      end
    end
  end
end
