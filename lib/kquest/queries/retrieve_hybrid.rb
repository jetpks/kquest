# frozen_string_literal: true

module Kquest
  module Queries
    # I03 families (a)/(b)/(c) — the hybrid retrieval, transcribed from
    # design/I03-retrieval/artifacts/queries-i03.sql:
    #   dense leg — cosine via pgvector `<=>` on the configured model's
    #               GENERATED table, user-scoped (every leg), quest-scopable
    #               (families a/a2), kinds filter (chunk/claim/frontier_need);
    #   FTS leg   — plainto_tsquery + ts_rank over `chunks.search_tsv` (the
    #               GENERATED column exists ONLY there — claims/needs carry
    #               NO tsvector, so they ride the dense leg only);
    #   fusion    — rrf(d) = w_dense·1/(60+rank_dense) + w_fts·1/(60+rank_fts),
    #               K = 60, weights 1.0, ranks 1-based via row_number over
    #               each leg's own ORDER BY with the frozen id tiebreaks; a
    #               document absent from a leg contributes 0 from that leg
    #               (the frozen formula's own semantics).
    # NO model parameter EVER reaches this object (I03 G-REG / T-NOMODEL) —
    # the model is registry config, resolved through the EmbedBridge.
    class RetrieveHybrid
      RRF_K = 60 # the frozen K (I03's D4 ruling)

      Hit = Struct.new(:kind, :id, :preview, :urn, :rrf, :dense_rank, :fts_rank, :cos_dist,
                       keyword_init: true)

      def initialize(conn:, bridge:)
        @conn = conn
        @bridge = bridge
      end

      # Returns the fused hits ordered by (rrf desc, rank-sum asc, id asc) —
      # the frozen ordering — capped by the caller. The query text is
      # embedded ONCE (one wire call per search).
      def search(user_id:, quest_id: nil, query:, kinds: %w[chunk claim frontier_need], limit: 10)
        vector = @bridge.vector_for(query)
        literal = @bridge.vector_literal(vector)
        table = @bridge.table

        dense_rank = {}
        dense_dist = {}
        dense_leg(user_id, quest_id, literal, table, kinds).each do |row|
          key = [row[:kind], row[:id]]
          dense_rank[key] = row[:rnk]
          dense_dist[key] = row[:cos_dist]
        end
        fts_rank = {}
        if kinds.include?("chunk")
          fts_leg(user_id, quest_id, query).each do |row|
            fts_rank[["chunk", row[:id]]] = row[:rnk]
          end
        end

        all_keys = dense_rank.keys | fts_rank.keys
        meta = hit_meta(user_id, all_keys)

        hits = all_keys.map do |key|
          dr = dense_rank[key]
          fr = fts_rank[key]
          # *** the RRF formula: an absent leg contributes 0 ***
          rrf = (dr ? 1.0 / (RRF_K + dr) : 0.0) + (fr ? 1.0 / (RRF_K + fr) : 0.0)
          m = meta[key]
          Hit.new(kind: key.first, id: key.last, preview: m[:preview], urn: m[:urn], rrf: rrf,
                  dense_rank: dr, fts_rank: fr, cos_dist: dr && (1.0 - dense_dist[key]).round(4))
        end
        # the frozen ORDER BY: rrf DESC, rank-sum ASC, id ASC
        hits.sort_by! { |h| [-h.rrf, (h.dense_rank || 1_000_000) + (h.fts_rank || 1_000_000), h.id] }
        hits.first(limit)
      end

      private

      # The dense leg per target kind (family a): ONE rank space across the
      # kinds (row_number over the union of the kinds' cosine rows — 1-based,
      # id tiebreak). The query vector rides in as a parameterized literal.
      def dense_leg(user_id, quest_id, literal, table, kinds)
        quest_filter = ->(tbl) { quest_id ? "AND #{tbl}.quest_id = :quest_id" : "" }
        arms = []
        arms << <<~SQL if kinds.include?("chunk")
          SELECT 'chunk' AS kind, ch.id AS id, (e.embedding <=> :literal::vector) AS cos_dist
          FROM #{table} e
          JOIN chunks ch ON ch.id = e.chunk_id
          WHERE e.user_id = :user_id AND e.target_kind = 'chunk'
        SQL
        arms << <<~SQL if kinds.include?("claim")
          SELECT 'claim' AS kind, cl.id AS id, (e.embedding <=> :literal::vector) AS cos_dist
          FROM #{table} e
          JOIN claims cl ON cl.id = e.claim_id
          WHERE e.user_id = :user_id AND e.target_kind = 'claim'
            #{quest_filter.call("cl")}
        SQL
        arms << <<~SQL if kinds.include?("frontier_need")
          SELECT 'frontier_need' AS kind, fe.id AS id, (e.embedding <=> :literal::vector) AS cos_dist
          FROM #{table} e
          JOIN frontier_entries fe ON fe.id = e.need_id
          WHERE e.user_id = :user_id AND e.target_kind = 'frontier_need'
            #{quest_filter.call("fe")}
        SQL
        return [] if arms.empty?

        @conn.fetch(<<~SQL, user_id: user_id, quest_id: quest_id, literal: literal).to_a
          WITH legs AS (
            #{arms.join("\nUNION ALL\n")}
          )
          SELECT kind, id, cos_dist,
                 row_number() OVER (ORDER BY cos_dist, id) AS rnk
          FROM legs
          ORDER BY cos_dist, id
        SQL
      end

      # The FTS leg (family b): plainto_tsquery ANDs the terms; ts_rank
      # orders; ranks 1-based with the id tiebreak. Chunks only.
      def fts_leg(user_id, quest_id, query)
        quest_filter = quest_id ? "AND EXISTS (SELECT 1 FROM quest_sources qs
                                            WHERE qs.source_id = c.source_id AND qs.quest_id = :quest_id)" : ""
        @conn.fetch(<<~SQL, user_id: user_id, quest_id: quest_id, query: query).to_a
          SELECT t.id, row_number() OVER (ORDER BY t.fts_rank DESC, t.id) AS rnk
          FROM (
            SELECT c.id, ts_rank(c.search_tsv, plainto_tsquery('english', :query)) AS fts_rank
            FROM chunks c
            WHERE c.user_id = :user_id #{quest_filter}
              AND c.search_tsv @@ plainto_tsquery('english', :query)
          ) t
          ORDER BY t.fts_rank DESC, t.id
        SQL
      end

      def hit_meta(user_id, keys)
        meta = {}
        chunk_ids = keys.select { |k, _| k == "chunk" }.map { |_, id| id }
        unless chunk_ids.empty?
          @conn[:chunks].join(:sources, Sequel[:sources][:id] => Sequel[:chunks][:source_id])
                        .where(Sequel[:chunks][:user_id] => user_id, Sequel[:chunks][:id] => chunk_ids)
                        .select(Sequel[:chunks][:id], Sequel[:chunks][:text], Sequel[:sources][:urn])
                        .each do |r|
            meta[["chunk", r[:id]]] = {preview: r[:text][0, 80], urn: r[:urn]}
          end
        end
        claim_ids = keys.select { |k, _| k == "claim" }.map { |_, id| id }
        unless claim_ids.empty?
          @conn[:claims].where(user_id: user_id, id: claim_ids)
                        .select(:id, :canonical_text, :urn).each do |r|
            meta[["claim", r[:id]]] = {preview: r[:canonical_text][0, 80], urn: r[:urn]}
          end
        end
        need_ids = keys.select { |k, _| k == "frontier_need" }.map { |_, id| id }
        unless need_ids.empty?
          @conn[:frontier_entries].where(user_id: user_id, id: need_ids)
                                  .select(:id, :need).each do |r|
            meta[["frontier_need", r[:id]]] = {preview: r[:need][0, 80], urn: nil}
          end
        end
        meta
      end
    end
  end
end
