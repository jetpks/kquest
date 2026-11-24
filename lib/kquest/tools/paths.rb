# frozen_string_literal: true

module Kquest
  module Tools
    # Derivation descent from one claim toward typed terminals (I01 Q1's
    # shape); refuses nothing but unknown starts and the depth belt
    # (`tools.cap_paths_depth` — the walk-the-tail recipe).
    class Paths < Base
      tool_name "paths"

      parameters do
        {"type" => "object",
         "properties" => {"node" => {"type" => "string"}},
         "required" => ["node"]}
      end

      def execute(**args)
        node = find_claim(args[:node].to_s)
        refuse("paths", "unknown-node", id: args[:node].to_s) unless node

        result = Kquest::Queries::DerivationPaths.new(conn: conn)
                                                 .paths(node.fetch(:id), user_id: user_id,
                                                        quest_id: quest_id,
                                                        depth_cap: cfg("tools.cap_paths_depth"))
        if result[:truncated]
          refuse("paths", "depth-cap", depth: "depth #{result[:max_depth]}")
        end

        lines = result[:terminals].map do |t|
          claim = conn[:claims].where(id: t[:node_id]).first
          "depth #{t[:depth]} → #{claim_alias(claim)} [#{t[:terminal_type]}] " \
            "#{claim.fetch(:text)[0, 80]}"
        end
        lines.empty? ? "#{claim_alias(node)} is a typed terminal (or derives nothing)" : lines.join("\n")
      end
    end
  end
end
