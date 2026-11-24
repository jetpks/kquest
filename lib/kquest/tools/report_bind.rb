# frozen_string_literal: true

module Kquest
  module Tools
    # The deterministic finalization pass (I05 §2 / I02 §9, transcribed):
    # builds the citation index, extracts inline `[^n]`, binds each to a
    # report_citations row, renders the footnote block, scans the body for
    # transcribed hashes, flips the standing pointer — all in ONE
    # transaction (the harness's audit transaction); same body + corpus +
    # manifest = same output byte-for-byte.
    class ReportBind < Base
      tool_name "report_bind"

      parameters do
        {"type" => "object",
         "properties" => {"version" => {"type" => "string"}},
         "required" => []}
      end

      def mutates? = true

      def execute(**_args)
        version = conn[:report_versions]
                  .where(quest_id: quest_id, created_session_id: session.fetch(:id))
                  .where(bound_at: nil).order(Sequel.desc(:version_seq)).first
        raise ArgumentError, "report_bind: no draft version to bind" unless version

        body = read_body(version)

        # The model never transcribes hashes (I02 §9's own law) — the hash
        # scan runs BEFORE any binding writes.
        if body.match?(Kquest::Queries::ReportBinding::HASH_TOKEN)
          refuse("report_bind", "hash-transcription")
        end

        binder = Kquest::Queries::ReportBinding.new(conn: conn)
        index = binder.citation_index(user_id: user_id, quest_id: quest_id)
        manifest = binder.import_manifest(version)

        begin
          result = binder.bind(user_id: user_id, quest_id: quest_id, version_row: version, body: body)
        rescue Kquest::Engine::Error => e
          if e.message.start_with?("citation [^") && e.message.match?(/\[\^(\d+)\]/)
            ordinal = e.message.match(/\[\^(\d+)\]/)[1].to_i
            # An unmarked OUT-OF-CORPUS citation: the ordinal names a source
            # the user's tenancy stages in ANOTHER quest — the import
            # manifest (tooling-minted) is the only legal route.
            outside = ordinal > index.size && manifest.find { |m| m[:ordinal] == ordinal }.nil? &&
                      conn[:quest_sources].join(:sources, Sequel[:sources][:id] => Sequel[:quest_sources][:source_id])
                                          .where(Sequel[:sources][:user_id] => user_id)
                                          .exclude(Sequel[:quest_sources][:quest_id] => quest_id).count.positive?
            if outside
              refuse("report_bind", "import-unmarked", ordinal: "[^#{ordinal}]")
            end
            refuse("report_bind", "ordinal-unbound",
                   ordinal: "[^#{ordinal}]",
                   corpus: "holds #{index.size} sources (ordinals 1..#{index.size})",
                   imports: "holds #{manifest.size} more")
          end
          raise
        end

        # The binding rows + the standing flip ride the harness's ONE
        # transaction (re-runs append nothing — uq per version).
        result[:citations].each do |c|
          next if conn[:report_citations].where(report_version_id: version[:id],
                                                ordinal: c[:ordinal]).first

          conn[:report_citations].insert(
            user_id: user_id, quest_id: quest_id, report_version_id: version.fetch(:id),
            ordinal: c[:ordinal],
            source_id: c[:imported] ? nil : c[:source_id],
            imported: c[:imported], import_source_quest_id: c[:import_source_quest_id],
            imported_source_id: c[:imported] ? c[:source_id] : nil
          )
        end

        # The footnote block rides the body blob (deterministic render).
        bound_body = body + "\n\n" + result[:footnote_block]
        Kquest::BlobUploader.store(StringIO.new(bound_body), kind: :report,
                                                             report_version_id: version.fetch(:id))

        now = Time.now
        conn[:report_versions].where(id: version.fetch(:id)).update(
          standing: true, bound_at: now,
          binding_pass: result[:footnote_block].empty? ? "empty" : "i02-9/i14",
          body_sha256: result[:body_sha256]
        )

        "report_bind: version #{version.fetch(:version_seq)} bound — " \
          "citations=#{result[:citations].size} ordinals dense footnote block rendered standing=true"
      end

      private

      def read_body(version)
        location = Kquest::BlobUploader.location_for(:report, report_version_id: version.fetch(:id))
        Kquest::BlobUploader.uploaded_file(JSON.generate({"id" => location, "storage" => "store"})).read
      rescue StandardError
        ""
      end
    end
  end
end
