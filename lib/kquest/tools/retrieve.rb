# frozen_string_literal: true

module Kquest
  module Tools
    # Hybrid retrieval (I05 §7.3 / I03 families a–c): dense + FTS legs, RRF
    # fusion (K=60), per-user scoped, quest-scopable; NO model parameter
    # EVER — a call supplying a model field is refused (T-NOMODEL / I03
    # G-REG at the tool). The dense leg embeds the query text ONCE via
    # Queries::EmbedBridge; the FTS leg exists where the generated tsvector
    # exists (chunks — claims/needs ride the dense leg only).
    class Retrieve < Base
      tool_name "retrieve"

      parameters do
        {"type" => "object",
         "properties" => {"query" => {"type" => "string"},
                          "kinds" => {"type" => "array",
                                      "items" => {"type" => "string",
                                                  "enum" => %w[chunk claim frontier_need]}},
                          "limit" => {"type" => "integer"},
                          "quest" => {"type" => "string"},
                          "model" => {"type" => "string"}},
         "required" => ["query"]}
      end

      def execute(**args)
        # T-NOMODEL: retrieval takes no model — the registry is the only
        # model path and kquest resolves it; resubmit without the field.
        refuse("retrieve", "model-name-refused") if args.key?(:model)

        kinds = args[:kinds] || %w[chunk claim frontier_need]
        bridge = Kquest::Queries::EmbedBridge.new(conn: conn, config: config)
        hits = Kquest::Queries::RetrieveHybrid.new(conn: conn, bridge: bridge)
                                              .search(user_id: user_id,
                                                      quest_id: args[:quest],
                                                      query: args[:query], kinds: kinds,
                                                      limit: args[:limit] || 10)
        hits.map do |h|
          scope = h.urn ? " [#{h.urn}]" : ""
          "[#{h.kind}] #{h.id}#{scope} rrf=#{h.rrf.round(4)} — #{h.preview}"
        end.join("\n")
      end
    end
  end
end
