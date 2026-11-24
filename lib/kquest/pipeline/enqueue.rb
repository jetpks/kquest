# frozen_string_literal: true

require "kernel/sync"

module Kquest
  module Pipeline
    # The caller-side mint (ENTRY 3+'s seam). Find-or-create by idem key over
    # the connection — the key derivations reproduce the I03 seed's example
    # forms verbatim. A failed attempt never pins the key
    # (uq_embed_jobs_idem_active excludes failed rows): the retry is a NEW
    # row sharing the idem key (the seed's j08→j07 pair).
    #
    # The push rides the app's ONE job queue (the Inline processor runs the
    # body in-request under test env — the full
    # enqueue→queue→runner→wire→ledger round is a named test).
    module Enqueue
      RESULT_CREATED = :created
      RESULT_RESUMED = :resumed
      RESULT_NOOP = :noop

      module_function

      # `embed:<model>:claim:quest:<qid>` / `embed:<model>:need:quest:<qid>`
      # / `embed:<model>:chunk:<strategy>`.
      def embed(model_id:, target_kind:, quest_id:, user_id:, phase_id: nil, strategy_id: nil,
                conn: Kquest::App["db.gateway"].connection)
        key = case target_kind
              when "claim" then "embed:#{model_id}:claim:quest:#{quest_id}"
              when "frontier_need" then "embed:#{model_id}:need:quest:#{quest_id}"
              when "chunk" then "embed:#{model_id}:chunk:#{strategy_id}"
              else raise Error, "unknown embed target_kind: #{target_kind.inspect}"
              end
        find_or_create(conn, key, user_id: user_id, quest_id: quest_id, phase_id: phase_id,
                       kind: "embed", model_id: model_id, target_kind: target_kind,
                       strategy_id: strategy_id, source_id: nil)
      end

      # `chunk:<strategy>:quest:<qid>` / `chunk:<strategy>:src:<sid>`.
      def chunk(strategy_id:, quest_id:, user_id:, source_id: nil, phase_id: nil,
                conn: Kquest::App["db.gateway"].connection)
        key = if source_id
                "chunk:#{strategy_id}:src:#{source_id}"
              else
                "chunk:#{strategy_id}:quest:#{quest_id}"
              end
        find_or_create(conn, key, user_id: user_id, quest_id: quest_id, phase_id: phase_id,
                       kind: "chunk", model_id: nil, target_kind: nil,
                       strategy_id: strategy_id, source_id: source_id)
      end

      def find_or_create(conn, key, user_id:, quest_id:, phase_id:, kind:,
                         model_id:, target_kind:, strategy_id:, source_id:)
        existing = conn[:embed_jobs]
          .where(idem_key: key)
          .where(Sequel[:state] =~ %w[pending running complete])
          .first
        if existing
          return push(existing[:id], status: existing[:state] == "complete" ? RESULT_NOOP : RESULT_RESUMED)
        end

        job_id = conn[:embed_jobs].insert(
          user_id: user_id,
          quest_id: quest_id,
          phase_id: phase_id,
          kind: kind,
          model_id: model_id,
          target_kind: target_kind,
          strategy_id: strategy_id,
          source_id: source_id,
          state: "pending",
          idem_key: key
        )
        push(job_id, status: RESULT_CREATED)
      end

      def push(job_id, status:)
        payload = {"embed_job_id" => job_id}
        if Async::Task.current?
          Kquest::App["job_queue"].call(payload)
        else
          Sync { Kquest::App["job_queue"].call(payload) }
        end
        {status: status, id: job_id}
      end
    end
  end
end
