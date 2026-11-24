# frozen_string_literal: true

require "digest"

module Kquest
  module Queries
    # The citation-binding pass (I02 §9 / queries-i02.sql B1, transcribed —
    # R-026/R-027): the deterministic finalization algorithm.
    #   1. citation index  — the quest's citable corpus
    #                        (quest_sources ⋈ sources WHERE role='citable')
    #                        ordered by (added_at, source_id); ordinals
    #                        1..N are RESERVED for this index (L10: stable,
    #                        cold-boot-recomputable, ranking-independent).
    #   2. import manifest — sources cited OUTSIDE the corpus ride the
    #                        synthesis phase's result.imports (ordinal beyond
    #                        N, source urn, origin quest) — minted by
    #                        TOOLING, never by the model.
    #   3. extraction      — the inline ordinal tokens [^n] from the body.
    #   4. binding         — ordinal n → the n-th citation-index source if
    #                        n ≤ N; else the manifest entry; each binding
    #                        becomes ONE report_citations row (uq per
    #                        version — re-runs append nothing).
    #   5. footnote block  — rendered deterministically as
    #                        [^n]: <urn> — <title>, <canonical_url>, fetched
    #                        <YYYY-MM-DD> plus the import suffix.
    # Same body + corpus + manifest = same output, byte-for-byte.
    class ReportBinding
      ORDINAL_TOKEN = /\[\^([0-9]+)\]/.freeze
      HASH_TOKEN = /kb:[0-9A-Za-z]+/.freeze

      def initialize(conn:)
        @conn = conn
      end

      # The citation index (the staging ordinal space — the SAME index
      # source_list's C-ids resolve by, I14's Grounds ruling).
      def citation_index(user_id:, quest_id:)
        @conn[:quest_sources]
          .join(:sources,
                Sequel[:sources][:id] => Sequel[:quest_sources][:source_id],
                Sequel[:sources][:user_id] => Sequel[:quest_sources][:user_id])
          .where(Sequel[:quest_sources][:quest_id] => quest_id,
                 Sequel[:quest_sources][:user_id] => user_id,
                 Sequel[:sources][:role] => "citable")
          .order(Sequel[:quest_sources][:added_at], Sequel[:quest_sources][:source_id])
          .select(Sequel[:sources][:id], Sequel[:sources][:urn], Sequel[:sources][:title],
                  Sequel[:sources][:canonical_url], Sequel[:sources][:fetched_at])
          .to_a
      end

      # The import manifest (the synthesis phase's result.imports).
      def import_manifest(version_row)
        phase = @conn[:phases].where(id: version_row.fetch(:synthesis_phase_id)).first
        return [] unless phase && phase.fetch(:result)

        Array(phase.fetch(:result)).filter_map do |entry|
          next unless entry.is_a?(Hash)

          {ordinal: entry["ordinal"].to_i, source_urn: entry["source_urn"],
           from_quest: entry["from_quest"]}
        end
      end

      # The deterministic pass over one body. Returns {citations:,
      # footnote_block:, body_sha256:}; inserts nothing — the caller (the
      # tool) opens the ONE transaction.
      def bind(user_id:, quest_id:, version_row:, body:)
        index = citation_index(user_id: user_id, quest_id: quest_id)
        manifest = import_manifest(version_row)
        ordinals = body.scan(ORDINAL_TOKEN).map(&:first).map(&:to_i).sort.uniq

        citations = ordinals.map do |n|
          if n <= index.size
            src = index[n - 1]
            {ordinal: n, source_id: src[:id], imported: false, import_source_quest_id: nil,
             urn: src[:urn], title: src[:title], canonical_url: src[:canonical_url],
             fetched_at: src[:fetched_at]}
          elsif (entry = manifest.find { |m| m[:ordinal] == n })
            src = @conn[:sources].where(user_id: user_id, urn: entry[:source_urn]).first
            raise Kquest::Engine::Error, "import manifest ordinal #{n}: no source with urn " \
                                         "#{entry[:source_urn].inspect}" unless src

            {ordinal: n, source_id: nil, imported: true,
             import_source_quest_id: entry[:from_quest],
             urn: src[:urn], title: src[:title], canonical_url: src[:canonical_url],
             fetched_at: src[:fetched_at]}
          else
            raise Kquest::Engine::Error, "citation [^#{n}] does not resolve"
          end
        end

        {citations: citations, footnote_block: footnote_block(citations),
         body_sha256: Digest::SHA256.hexdigest(body)}
      end

      # The footnote block (deterministic; fetched = date-granular, I02 §9).
      def footnote_block(citations)
        citations.map do |c|
          line = "[^#{c[:ordinal]}]: #{c[:urn]} — #{c[:title]}, #{c[:canonical_url]}, " \
                 "fetched #{c[:fetched_at].strftime('%Y-%m-%d')}"
          c[:imported] ? line + " [IMPORT from quest #{c[:import_source_quest_id]}]" : line
        end.join("\n")
      end
    end
  end
end
