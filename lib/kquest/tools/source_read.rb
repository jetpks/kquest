# frozen_string_literal: true

module Kquest
  module Tools
    # SLICED snapshot reads (I05 §7.3 / DR-04): `offset` (1-based line) /
    # `limit` (lines, default 60), capped 8,000 chars per slice
    # (`engine.read_slice_cap_chars`, mode HARD per I05 DR-04 ruling A → the
    # frozen `non-sliced-read` refusal naming the slice form + the
    # grep-first pattern; an operator flip to advisory executes with the
    # cap-continuation note — never silent). The snapshot text is read
    # through the BlobUploader location pattern (`ChunkBody#read_snapshot` —
    # in-memory in test).
    class SourceRead < Base
      tool_name "source_read"

      DEFAULT_LIMIT = 60

      parameters do
        {"type" => "object",
         "properties" => {"src" => {"type" => "string"},
                          "offset" => {"type" => "integer"},
                          "limit" => {"type" => "integer"}},
         "required" => ["src"]}
      end

      def execute(**args)
        source = resolve(args[:src])
        lines = snapshot_lines(source).map(&:chomp)

        offset = args[:offset] || 1
        limit = args[:limit] || DEFAULT_LIMIT
        if offset > lines.size
          refuse("source_read", "offset-beyond-eof",
                 offset: "offset #{offset}",
                 lines: "#{lines.size} lines",
                 range: "1..#{lines.size}")
        end

        slice = lines[(offset - 1), limit].compact.map(&:chomp).join("\n")
        cap = cfg("engine.read_slice_cap_chars")
        line = cfg_mode("engine.read_slice_cap_chars")
        if slice.length > cap
          if line == "hard"
            refuse("source_read", "non-sliced-read",
                   src: source.fetch(:urn),
                   cap_seg: "cap #{cap} chars/slice")
          end
          # advisory mode executes WITH the cap-continuation note — never silent
          slice = slice[0, cap]
          slice += " " + cap_note(n: cap, last_id: "L#{offset + limit - 1}")
        end
        slice
      end

      private

      def resolve(ref)
        source = Kquest::Queries.resolve_source(conn, user_id: user_id, quest_id: quest_id, ref: ref.to_s)
        unless source
          refuse("source_read", "unknown-source", src: ref.to_s)
        end
        source
      end

      def snapshot_lines(source)
        location = Kquest::BlobUploader.location_for(:snapshot, user: user_id,
                                                            source_urn: source.fetch(:urn))
        Kquest::BlobUploader.uploaded_file(JSON.generate({"id" => location, "storage" => "store"}))
                            .read.lines
      end
    end
  end
end
