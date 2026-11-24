# frozen_string_literal: true

require "json"

module Kquest
  module Orchestrator
    # The XADD producer (I08 §3.1): one redis stream per scope, the capped
    # ticker idiom — `XADD <key> MAXLEN ~ 5000 * type <event> data <json>`.
    # Keys `kquest:sse:quest:<quest_uuid>` and `kquest:sse:user:<user_uuid>`;
    # the envelope is EXACTLY the two fields (`type`, `data` — `data` a single
    # JSON object); the redis ms-seq entry id rides the SSE `id:` line
    # (app/stream_action.rb's adopted frame, unchanged).
    class EventPublisher
      # I08 §3.2's catalog — the ten event types this entry produces/consumes.
      EVENT_TYPES = %w[
        quest.state quest.stop phase.state session.state tool.event
        spend.tick frontier.mass assurance_alert subagent.run watcher.bytes
      ].freeze

      MAXLEN_ENTRIES = 5000 # approximate cap — the stream is a tail, PG is the truth

      def initialize(redis:, prefix: "kquest", maxlen_entries: MAXLEN_ENTRIES)
        @redis = redis
        @prefix = prefix
        @maxlen = maxlen_entries
      end

      def quest_key(quest_uuid) = "#{@prefix}:sse:quest:#{quest_uuid}"

      def user_key(user_uuid) = "#{@prefix}:sse:user:#{user_uuid}"

      # Publish one catalog event onto the owning quest's stream.
      def publish_quest(quest_uuid, event, data)
        xadd(quest_key(quest_uuid), event, data)
      end

      # Publish one event onto the owning user's global stream (the
      # cross-quest assurance fires ride both scopes — I08 §3.4).
      def publish_user(user_uuid, event, data)
        xadd(user_key(user_uuid), event, data)
      end

      private

      def xadd(key, event, data)
        payload = data.is_a?(String) ? data : JSON.generate(data)
        @redis.call("XADD", key, "MAXLEN", "~", @maxlen.to_s, "*",
                    "type", event, "data", payload)
      end
    end
  end
end
