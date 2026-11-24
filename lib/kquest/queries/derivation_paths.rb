# frozen_string_literal: true

module Kquest
  module Queries
    # I01 canonical query Q1 (+ its Q1V violation half), transcribed from
    # design/I01-core-model/artifacts/canonical-queries.sql: the recursive
    # derivation descent from ONE origin claim through `derives_from` to
    # TYPED terminals (L2's positive half), principled order (depth, then
    # node id); the dangling-leaf half (Q1V) is the closure surfaces'
    # violation data. The `tools.cap_paths_depth` budget bounds the walk —
    # the paths tool's depth-cap refusal names the depth reached.
    class DerivationPaths
      def initialize(conn:)
        @conn = conn
      end

      # The descent rows: {depth, terminal_claim_id, terminal_type, node_id}
      # ordered by (depth, node_id). `truncated` is true when the walk was
      # cut at the depth cap before bottoming out.
      def paths(claim_id, user_id:, quest_id:, depth_cap:)
        params = {claim_id: claim_id, user_id: user_id, quest_id: quest_id, depth_cap: depth_cap}
        # Q1's walk (origin-parameterized): claim → its derivation parents,
        # transitively, keeping each row's terminal typing.
        rows = @conn.fetch(<<~SQL, params).to_a
          WITH RECURSIVE walk (node_id, depth, terminal_type) AS (
            SELECT d.parent_claim_id, 1, p.terminal_type
            FROM claim_derivations d
            JOIN claims p ON p.id = d.parent_claim_id
            WHERE d.claim_id = :claim_id AND d.user_id = :user_id AND d.quest_id = :quest_id
            UNION ALL
            SELECT d.parent_claim_id, w.depth + 1, p.terminal_type
            FROM walk w
            JOIN claim_derivations d ON d.claim_id = w.node_id
              AND d.user_id = :user_id AND d.quest_id = :quest_id
            JOIN claims p ON p.id = d.parent_claim_id
            WHERE w.depth < :depth_cap
          )
          SELECT node_id, depth, terminal_type FROM walk
        SQL
        terminals = rows.select { |r| r[:terminal_type] }
        max_depth = rows.map { |r| r[:depth] }.max || 0
        {terminals: terminals.sort_by { |r| [r[:depth], r[:node_id]] },
         max_depth: max_depth,
         truncated: max_depth >= depth_cap && rows.any? { |r| r[:depth] == depth_cap }}
      end

      # Q1V's dangling-leaf half: walk nodes that are not terminal, have no
      # further derivations, and carry no open frontier entry (the closure
      # contract broken mid-chain).
      def dangling_leaves(user_id:, quest_id:)
        @conn.fetch(<<~SQL, user_id: user_id, quest_id: quest_id).to_a
          WITH RECURSIVE walk (node_id, depth, terminal_type) AS (
            SELECT d.parent_claim_id, 1, p.terminal_type
            FROM claim_derivations d
            JOIN claims p ON p.id = d.parent_claim_id
            WHERE d.user_id = :user_id AND d.quest_id = :quest_id
            UNION ALL
            SELECT d.parent_claim_id, w.depth + 1, p.terminal_type
            FROM walk w
            JOIN claim_derivations d ON d.claim_id = w.node_id
              AND d.user_id = :user_id AND d.quest_id = :quest_id
            JOIN claims p ON p.id = d.parent_claim_id
          )
          SELECT DISTINCT w.node_id AS dangling_claim_id, w.depth
          FROM walk w
          WHERE w.terminal_type IS NULL
            AND NOT EXISTS (SELECT 1 FROM claim_derivations d WHERE d.claim_id = w.node_id)
            AND NOT EXISTS (SELECT 1 FROM frontier_entries f
                            WHERE f.claim_id = w.node_id AND f.state = 'open')
          ORDER BY w.depth, w.node_id
        SQL
      end
    end
  end
end
