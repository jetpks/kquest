# frozen_string_literal: true

require "json"
require "securerandom"
require "socket"
require "time"

module Kquest
  module Orchestrator
    # The redis-backed worker liveness registry (I08 §2.3, DR-04): every
    # worker process holds a heartbeat key
    # `kquest:worker:<worker_uuid>` — value JSON
    # `{pid, kind, host, boot_at, quest_id?, session_ids: []}` — with a TTL of
    # 3× the 10 s heartbeat (30 s). A dead worker's entry disappears with it
    # (I04 DR-05's requirement, verbatim: "worker liveness is the honest crash
    # signal ... unlike heartbeat columns or pidfiles"); the TTL is the
    # mechanism — no reaper can leak a stale liveness key. The value's
    # `session_ids` is this entry's recorded ruling: the redis analogue of the
    # landed in-process session Set — a session is live-held IFF a live
    # worker's entry lists it (the direct input to the launch gate's
    # liveness port and the reaper's sweep).
    #
    # Redis is liveness RUNTIME state, never durable law (I01 DR-12 posture).
    # All calls are fiber-native (the async-redis client) — callers run inside
    # a reactor (the quest worker, the launcher, the tests' Sync blocks).
    class WorkerRegistry
      # The I08 DR-04 key shape (documented here so the law is greppable at
      # the implementation): `kquest:worker:<worker_uuid>`.
      DEFAULT_PREFIX = "kquest"
      HEARTBEAT_S = 10
      TTL_S = 30 # 3× the heartbeat

      attr_reader :worker_uuid, :kind, :quest_id

      # redis: an async-redis client (the app's pooled `redis` dep or a
      # test-local client); prefix: the key namespace (tests use a
      # test-prefixed namespace and clean up — never dev's db 0 keys).
      def initialize(redis:, kind:, quest_id: nil, prefix: DEFAULT_PREFIX,
                     heartbeat_s: HEARTBEAT_S, ttl_s: TTL_S, host: Socket.gethostname)
        @redis = redis
        @kind = kind
        @quest_id = quest_id
        @prefix = prefix
        @heartbeat_s = heartbeat_s
        @ttl_s = ttl_s
        @host = host
        @worker_uuid = SecureRandom.uuid
        @session_ids = []
        @boot_at = Time.now.utc.iso8601
      end

      # Claim the registry entry (first write sets the key + TTL).
      def register!(session_ids: [])
        @session_ids = Array(session_ids)
        write_key
        self
      end

      # Refresh the TTL + the current session list (the periodic heartbeat).
      def heartbeat!(session_ids: @session_ids)
        @session_ids = Array(session_ids)
        write_key
        self
      end

      def claim_session!(session_id)
        @session_ids << session_id unless @session_ids.include?(session_id)
        write_key
        nil
      end

      def release_session!(session_id)
        @session_ids -= [session_id]
        write_key
        nil
      end

      # This worker's own liveness (the key exists = alive; the TTL expires it).
      def live?
        !@redis.call("EXISTS", key).zero?
      end

      # A session is live-held iff a LIVE worker's value lists it (DR-05
      # verbatim). A dead worker's key is gone, so its sessions are unheld.
      def self.session_live?(redis, prefix: DEFAULT_PREFIX, session_id:)
        live_workers(redis, prefix: prefix).any? do |worker|
          Array(worker[:value]["session_ids"]).include?(session_id.to_s)
        end
      end

      def session_live?(session_id)
        self.class.session_live?(@redis, prefix: @prefix, session_id: session_id)
      end

      # Every live worker entry: [{worker_uuid:, value: (parsed JSON)}].
      def self.live_workers(redis, prefix: DEFAULT_PREFIX)
        pattern = "#{prefix}:worker:*"
        entries = []
        cursor = "0"
        loop do
          _cursor, keys = redis.call("SCAN", cursor, "MATCH", pattern, "COUNT", 100)
          keys.each do |key|
            raw = redis.call("GET", key)
            next unless raw

            entries << {worker_uuid: key.to_s.delete_prefix("#{prefix}:worker:"),
                        value: JSON.parse(raw)}
          end
          cursor = _cursor
          break if cursor == "0" || cursor.to_i.zero?
        end
        entries
      end

      def live_workers
        self.class.live_workers(@redis, prefix: @prefix)
      end

      # Exit path: drop the key explicitly (the TTL would also expire it —
      # an orderly exit does not wait 30 s to look dead).
      def unregister!
        @redis.call("DEL", key)
        nil
      end

      def key = "#{@prefix}:worker:#{@worker_uuid}"

      private

      def write_key
        payload = {pid: Process.pid, kind: @kind, host: @host, boot_at: @boot_at,
                   session_ids: @session_ids.map(&:to_s)}
        payload[:quest_id] = @quest_id.to_s if @quest_id
        @redis.call("SET", key, JSON.generate(payload), "EX", @ttl_s)
        nil
      end
    end
  end
end
