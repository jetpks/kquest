# frozen_string_literal: true

module Kquest
  module Engine
    # The ONLY component that knows providers (I04 §3, R-038/R-041):
    # constructs the gem's `Client`/`Model` from an `llm_providers` row —
    # `Kquest::Pipeline::KeyRef` resolves the api_key_ref (consumed law, never
    # duplicated; NULL/empty → nil → no Authorization header), the dialect is
    # resolved BOOT-LOUD (E-PROTO/FM-10: an unknown dialect name raises
    # ArgumentError at construction, never on the wire). Mints ONE
    # session-scoped SeedDecorator per session (DR-07 mechanism a — the ONLY
    # seed/session_id delivery path, judge F1); per-provider ceilings and
    # cache-wall values read from the row. The underlying Client is closed at
    # session end (SessionSupervisor owns bank/cancel). Model swap at pause is
    # a config re-read — these are the MECHANICS; the routing policy is
    # ENTRY 4's.
    class ProviderDesk
      # The gem's Model requires an Integer max_tokens ceiling; a NULL row
      # value falls back to the row's context_window (the request cap stays
      # the gem's context-aware clamp — never the raw window).
      NULL_MAX_TOKENS_FALLBACK = :context_window

      attr_reader :row, :session, :model, :client, :spend

      # conn:        the Sequel connection (injection discipline)
      # provider_row: an llm_providers row Hash (never a literal)
      # session:     {id:, user_id:, quest_id:, phase_id:, model:}
      # watch:       optional StreamWatch (a second telemetry sink)
      def initialize(conn:, provider_row:, session:, watch: nil, spend: nil)
        @conn = conn
        @row = provider_row
        @session = session

        dialect = resolve_dialect!(row[:dialect]) # boot-loud (FM-10)
        @model = Fast::Completions::Model.new(
          id: row.fetch(:model_id),
          reasoning: row.fetch(:reasoning),
          context_window: row.fetch(:context_window),
          max_tokens: row[:max_tokens] || row.fetch(:context_window),
          thinking_level_map: row[:thinking_level_map],
          dialect: dialect,
          provider: row.fetch(:name)
        )

        seed_holder = []
        @spend = spend || SpendRecorder.new(conn: conn, session: session, provider_row: row,
                                            seed_source: -> { seed_holder[0] })
        sinks = [@spend]
        sinks << watch if watch
        @client = Fast::Completions::Client.new(
          base_url: row.fetch(:base_url),
          api_key: Kquest::Pipeline::KeyRef.resolve(row[:api_key_ref]),
          timeout: row[:timeout_s] || Fast::Completions::Client::DEFAULT_TIMEOUT,
          max_retries: row.key?(:max_retries) && !row[:max_retries].nil? \
                       ? row[:max_retries] : Fast::Completions::Client::DEFAULT_MAX_RETRIES,
          ttfb_timeout: row[:ttfb_timeout_s],
          inactivity_timeout: row[:inactivity_timeout_s],
          telemetry: sinks
        )
        @decorator = SeedDecorator.new(@client, session_id: session[:id],
                                       seed_sink: ->(seed) { seed_holder[0] = seed })
      end

      # THE Chat-path client: the session-scoped decorator (every `Chat#step`
      # through it carries the fresh seed + the session id for affinity when
      # the dialect supports it).
      def client
        @decorator
      end

      # The FM-02 size-ceiling bands (per-provider config, DR-06).
      def transcript_ceiling_warn_bytes = Integer(row.fetch(:transcript_ceiling_warn_bytes))
      def transcript_ceiling_hard_bytes = Integer(row.fetch(:transcript_ceiling_hard_bytes))

      # The FM-24 prefix-cache wall (NULL = no wall configured).
      def cache_wall_tokens = row[:cache_wall_tokens]

      # The provider's per-call usage-reporting posture (FM-25): a dialect
      # with supports_usage_in_streaming: false cannot report usage — the
      # config-time warning + per-call zero-row honesty marker.
      def reports_usage? = model.dialect.supports_usage_in_streaming

      def close
        @client.close
        nil
      end

      private

      # Boot-loud dialect law: nil = the plain OpenAI arm; a Symbol/String
      # name must be a DECLARED dialect (the shipped :zai/:deepseek/:fireworks
      # or a custom declaration) — an undeclared name raises ArgumentError at
      # construction, never a silent plain-arm fallback (FM-10).
      def resolve_dialect!(name)
        return nil if name.nil? || name.to_s.empty?

        symbol = name.to_sym
        begin
          Fast::Completions::Dialects.fetch(symbol)
        rescue KeyError
          raise ArgumentError,
                "unknown dialect declaration #{symbol.inspect} on provider row " \
                "#{row[:name].inspect} — declare it (Fast::Completions.dialect) or use a shipped " \
                "declaration (#{Fast::Completions::Dialects.registered.inspect}); " \
                "a mis-declared dialect is a config defect caught at boot, never a runtime retry"
        end
        symbol
      end
    end
  end
end
