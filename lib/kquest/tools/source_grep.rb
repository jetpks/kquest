# frozen_string_literal: true

module Kquest
  module Tools
    # Grep-over-content (I05 §7.3): pattern → matching line numbers + context
    # lines; the locate-first half of grep-then-slice; runs under the tool
    # deadline (the class-B wedge law — the harness wraps every execute).
    class SourceGrep < Base
      tool_name "source_grep"

      parameters do
        {"type" => "object",
         "properties" => {"src" => {"type" => "string"},
                          "pattern" => {"type" => "string"},
                          "ignore_case" => {"type" => "boolean"},
                          "context" => {"type" => "integer"}},
         "required" => ["src"]}
      end

      def execute(**args)
        source = Kquest::Queries.resolve_source(conn, user_id: user_id, quest_id: quest_id,
                                                       ref: args[:src].to_s)
        unless source
          refuse("source_grep", "unknown-source", src: args[:src].to_s)
        end

        pattern = args[:pattern].to_s
        refuse("source_grep", "pattern-required") if pattern.strip.empty?

        regex = Regexp.new(Regexp.escape(pattern), args[:ignore_case] ? Regexp::IGNORECASE : 0)
        context = (args[:context] || 0).to_i
        lines = snapshot_lines(source)

        out = []
        lines.each_with_index do |line, i|
          next unless line.match?(regex)

          ((i - context)..(i + context)).each do |j|
            next if j.negative? || j >= lines.size || out.any? { |(n, _)| n == j + 1 }

            out << [j + 1, lines[j].chomp]
          end
        end
        out.map { |(n, text)| "#{n}: #{text}" }.join("\n")
      end

      private

      def snapshot_lines(source)
        location = Kquest::BlobUploader.location_for(:snapshot, user: user_id,
                                                            source_urn: source.fetch(:urn))
        Kquest::BlobUploader.uploaded_file(JSON.generate({"id" => location, "storage" => "store"}))
                            .read.lines
      end
    end
  end
end
