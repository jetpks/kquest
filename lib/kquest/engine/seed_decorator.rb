# frozen_string_literal: true

module Kquest
  module Engine
    # The ProviderDesk-owned Client decorator (I04 DECISIONS DR-07, mechanism
    # a — judge F1's delivery path): `Chat#step` calls `#stream` with a FIXED
    # kwarg set (model/messages/instructions/tools/thinking/max_tokens — no
    # temperature, no seed, no session_id), so a bare Client-level kwarg is
    # dead code on the Chat path. THIS decorator is the ONE seed/session
    # delivery point: `#stream` fill-injects a fresh random seed per request
    # (an explicit seed wins — deterministic replay tooling) and forwards the
    # session id before delegating, so every kwarg the gem's `Client#stream`
    # takes passes through untouched. Every RETRY is a fresh `Chat#step` → a
    # fresh injection → an identical (body, seed) re-attempt is structurally
    # impossible (FM-03/E-SEED).
    #
    # NO Chat surface, NO `raw_stream` (DR-07's rejected alternatives stay
    # rejected — the loop never re-implements the Chat, I04 DR-13).
    class SeedDecorator
      # The fresh fill seed's range: a positive Integer per the usage_events
      # seed CHECK (`seed IS NULL OR seed >= 0`).
      SEED_RANGE = 0...2**31

      def initialize(client, session_id: nil, seed_sink: nil, random: Random)
        @client = client
        @session_id = session_id
        @seed_sink = seed_sink
        @random = random
      end

      # The last seed this decorator served (the replay-diagnosis fact the
      # SpendRecorder echoes into usage_events.seed).
      def last_served_seed
        @served
      end

      # Client#stream's exact kwarg surface, with the seed fill and the
      # session id defaulted. All other kwargs forward untouched.
      def stream(model:, messages:, instructions: nil, tools: [], thinking: nil,
                 max_tokens: nil, temperature: nil, seed: nil, session_id: nil, &block)
        served = seed.nil? ? @random.rand(SEED_RANGE) : seed # explicit wins
        @served = served
        @seed_sink&.call(served)
        @client.stream(model: model, messages: messages, instructions: instructions,
                       tools: tools, thinking: thinking, max_tokens: max_tokens,
                       temperature: temperature, seed: served,
                       session_id: session_id || @session_id, &block)
      end

      # Everything else IS the client (close, dropped_chunks, ...).
      def respond_to_missing?(name, include_private = false)
        @client.respond_to?(name, include_private) || super
      end

      def method_missing(name, *args, **kwargs, &block)
        if @client.respond_to?(name)
          @client.public_send(name, *args, **kwargs, &block)
        else
          super
        end
      end
    end
  end
end
