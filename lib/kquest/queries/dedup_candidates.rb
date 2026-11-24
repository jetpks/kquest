# frozen_string_literal: true

module Kquest
  module Queries
    # I03 family (d) — the dedup-by-construction candidate check (R-036 /
    # I05 DR-07), transcribed from design/I03-retrieval/artifacts/
    # queries-i03.sql. Two legs, one result set:
    #   exact — canonical_text byte-equality (the I01 DR-05 generated
    #           normalizer; the uq_claims_quest_canonical law), user-scoped
    #           (the hub is per-user, D3/D6);
    #   near  — cosine neighbors in the CLAIM vectors of the CONFIGURED model
    #           (`tools.claim_embedding_model` → its registry-derived table
    #           name — the sanctioned G-REG exception), user-scoped,
    #           top-`k` under the floor — **k and floor READ FROM
    #           `tool_config`, never hardcoded** (the frozen bounds: floor
    #           within [0.30, 0.95], k integer within [1, 50]).
    # Results map onto `v_canonical_claims` entries (the I02 DR-16 hub seam)
    # with match_kind ∈ {exact, near_dup} + cosine. The check runs BEFORE the
    # write (node_add): an exact match refuses; near-dups NEVER refuse — they
    # surface with the frozen dedup-candidates note.
    class DedupCandidates
      def initialize(conn:)
        @conn = conn
      end

      Result = Struct.new(:match_kind, :claim_id, :quest_id, :quest_seq, :canonical_text,
                          :terminal_type, :cosine, :hub_entry, keyword_init: true)

      def candidates(user_id:, text:, probe_vector: nil)
        exact = exact_leg(user_id, text)
        near = probe_vector ? near_leg(user_id, probe_vector, exclude: exact.map { |r| r[:claim_id] }) : []

        exact_rows = exact.map do |r|
          Result.new(match_kind: "exact", claim_id: r[:id], quest_id: r[:quest_id],
                     quest_seq: r[:quest_seq],
                     canonical_text: r[:canonical_text], terminal_type: r[:terminal_type],
                     cosine: 1.0, hub_entry: hub_entry(user_id, r[:canonical_text], r[:terminal_type]))
        end
        near_rows = near.map do |r|
          Result.new(match_kind: "near_dup", claim_id: r[:claim_id], quest_id: r[:quest_id],
                     quest_seq: r[:quest_seq],
                     canonical_text: r[:canonical_text], terminal_type: r[:terminal_type],
                     cosine: (1.0 - r[:cos_dist]).round(4),
                     hub_entry: hub_entry(user_id, r[:canonical_text], r[:terminal_type]))
        end
        {exact: exact_rows, near: near_rows}
      end

      private

      # The frozen normalizer (the GENERATED column's definition, mirrored —
      # PipelineFixtures.mint_claim's own mirror).
      def canonicalize(text)
        text.gsub(/[ \t\n\r\f\v]+/, " ").strip
          .gsub(/\A[ \t\n\r\f\v]+|[ \t\n\r\f\v]+\z/, "")
          .unicode_normalize(:nfc)
      end

      def exact_leg(user_id, text)
        canonical = canonicalize(text)
        @conn[:claims]
          .where(user_id: user_id, canonical_text: canonical)
          .order(:quest_id, :id)
          .select(:id, :quest_id, :quest_seq, :canonical_text, :terminal_type)
          .to_a
      end

      # The near leg: cosine neighbors in the configured model's claim
      # vectors, user-scoped, ORDER by distance + id tiebreak, LIMIT k, then
      # the floor cut (cosine = 1 − cosine_distance) — the frozen family (d)
      # shape (`top-k under a floor`).
      def near_leg(user_id, probe_vector, exclude:)
        k = k_value
        floor = floor_value
        table = vector_table
        literal = "[#{probe_vector.join(",")}]"
        rows = @conn.fetch(<<~SQL, user_id: user_id, literal: literal, k: k)
          SELECT c.id AS claim_id, c.quest_id, c.quest_seq, c.canonical_text, c.terminal_type,
                 (e.embedding <=> :literal::vector) AS cos_dist
          FROM #{table} e
          JOIN claims c ON c.id = e.claim_id
          WHERE e.user_id = :user_id
            AND e.target_kind = 'claim'
          ORDER BY e.embedding <=> :literal::vector, c.id
          LIMIT :k
        SQL
        rows.reject { |r| exclude.include?(r[:claim_id]) }
            .select { |r| (1.0 - r[:cos_dist]) >= floor && r[:cos_dist] < 1.0 }
      end

      # The registry-derived table name (the sanctioned G-REG exception —
      # the table name IS registry data; validated against the registry's
      # own name law before it ever reaches SQL).
      def vector_table
        model_id = Queries.config_value(@conn, "tools.claim_embedding_model")
        row = @conn[:embedding_models].where(id: model_id).first
        raise Kquest::Pipeline::Error, "registry row #{model_id.inspect} not found (G-REG)" unless row

        name = row.fetch(:table_name)
        raise Kquest::Pipeline::Error, "registry table_name #{name.inspect} is not a legal " \
                                       "generated-table name" unless name =~ /\Aemb_[a-z0-9_]+\z/

        name
      end

      def k_value
        k = Queries.config_value(@conn, "tools.dedup_near_top_k")
        k = k.to_i
        raise Kquest::Pipeline::Error, "tools.dedup_near_top_k must be an integer within [1, 50], " \
                                       "got #{k}" unless k.between?(1, 50)

        k
      end

      def floor_value
        floor = Queries.config_value(@conn, "tools.dedup_near_floor").to_f
        raise Kquest::Pipeline::Error, "tools.dedup_near_floor must be within [0.30, 0.95], " \
                                       "got #{floor}" unless floor.between?(0.30, 0.95)

        floor
      end

      # The hub seam: the candidate mapped onto its v_canonical_claims entry
      # (I02 DR-16's growth slot — the same view the exact leg reads).
      def hub_entry(user_id, canonical_text, terminal_type)
        @conn[:v_canonical_claims]
          .where(user_id: user_id, canonical_text: canonical_text)
          .where(Sequel[:terminal_type] => terminal_type)
          .first
      end
    end
  end
end
