# frozen_string_literal: true

module Kquest
  module Queries
    # The query-text → vector seam (I14 Part 5.8): resolves the configured
    # model's registry row, speaks the landed pipeline wire
    # (`Pipeline::Wire.client_for` → fast-embeddings 0.1.1 — ONE attempt per
    # call, no retry machinery; callers retry per the landed governor
    # classes), and returns vectors for `<=>` SQL plus the wire's usage echo.
    # The model is config: `tools.claim_embedding_model` names the registry
    # ROW (a uuid); no model name literal ever appears here (G-REG).
    #
    # Batch discipline is the caller's — the gem crosses input VERBATIM — so
    # the bridge slices by the registry row's batch_max_texts AND
    # input_max_chars. Keyless tests point `tools.claim_embedding_model` at
    # their OWN upserted registry row whose endpoint is the in-process mock
    # embeddings server; the pristine bge-m3 row is never touched by tests.
    class EmbedBridge
      TABLE_PATTERN = /\Aemb_[a-z0-9_]+\z/

      def initialize(conn:, config:, model_id: nil)
        @conn = conn
        @config = config
        # The injected config WINS (the harness carries the DB-derived lines);
        # else the DB row; else the frozen fallback.
        key = "tools.claim_embedding_model"
        # The DB's tool_config ROW is the operative config data (the seeds'
        # delete+insert law re-heals it); the injected config is the fallback
        # when the row is absent, then the frozen default.
        @model_id = model_id ||
                    (conn[:tool_config].where(key: key).first && Queries.config_value(conn, key)) ||
                    (config.key?(key) ? Tools.config_value(config, key)
                                      : Tools::DEFAULT_CONFIG.fetch(key))
      end

      attr_reader :model_id

      def model_row
        @model_row ||= @conn[:embedding_models].where(id: @model_id).first or
                       raise Kquest::Pipeline::Error,
                             "registry row #{@model_id.inspect} not found — the embedding registry " \
                             "is the only model path (G-REG)"
      end

      # The registry-derived vector table (the sanctioned name form — the
      # table name IS registry data; validated against the registry's own
      # name law before it ever reaches SQL).
      def table
        name = model_row.fetch(:table_name)
        raise Kquest::Pipeline::Error, "registry table_name #{name.inspect} is not a legal " \
                                       "generated-table name" unless name =~ TABLE_PATTERN

        name
      end

      def dimensions = model_row.fetch(:dimensions)

      # Embeds the texts (registry-batch-sized calls), returns
      # {vectors: [Array<Float>…], usage: {prompt_tokens:, total_tokens:}} —
      # the usage echo is the caller's spend record.
      def embed(texts)
        client = Kquest::Pipeline::Wire.client_for(model_row)
        api_key = Kquest::Pipeline::KeyRef.resolve(model_row.fetch(:api_key_ref))
        batch_size = model_row.fetch(:batch_max_texts)
        max_chars = model_row.fetch(:input_max_chars)

        vectors = []
        prompt_tokens = 0
        total_tokens = 0
        texts.each_slice(batch_size) do |batch|
          result = client.embed(model: model_row.fetch(:wire_name), input: batch, api_key: api_key)
          raise Kquest::Pipeline::Error, "embeddings reply is not batch-aligned" \
            unless result.data.size == batch.size

          vectors.concat(result.data.sort_by(&:index).map(&:embedding))
          prompt_tokens += result.usage.prompt_tokens
          total_tokens += result.usage.total_tokens
          _ = max_chars # the caller pre-slices texts to input_max_chars
        end
        {vectors: vectors, usage: {prompt_tokens: prompt_tokens, total_tokens: total_tokens}}
      end

      def vector_for(text)
        embed([text]).fetch(:vectors).first
      end

      # The pgvector text-literal form for `<=>` SQL (parameterized by the
      # caller — never interpolated from user input).
      def vector_literal(vector)
        "[#{vector.join(",")}]"
      end
    end
  end
end
