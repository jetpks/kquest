# frozen_string_literal: true

module Kquest
  module Orchestrator
    # The job worker's own orphan sweep (I08 §2.3): at boot (+ periodic),
    # `embed_jobs` rows in `running` whose scopes are not claimed by any live
    # job-worker heartbeat are RESUMED from `done_items` (the row re-enters
    # `pending` and is re-enqueued — the pipeline body restarts at the
    # `done_items` cursor, J-IDEM: complete rows are no-ops) or marked
    # `failed` with the error pair (`ck_embed_jobs_error_pair`: started_at,
    # ended_at, error_note) when the resume is impossible (the model row is
    # gone — an unroutable job cannot be honestly re-enqueued). The job
    # worker is the SINGLETON class (DR-02) — its boot-time sweep is honest:
    # if no live job-worker heartbeat exists, every `running` row is orphaned.
    #
    # The job-worker claim is the registry: live `kind: "job"` entries hold
    # the job scope (the singleton worker claims ALL embed_jobs scope — the
    # value's `quest_id` stays nil; presence of a live job worker is the
    # claim). MUTATES (the consequence half).
    class JobSweeper
      def initialize(conn:, registry:)
        @conn = conn
        @registry = registry
      end

      # Returns {resumed: [job_id], failed: [job_id]} — the sweep's observable.
      def sweep
        result = {resumed: [], failed: []}
        return result if job_worker_live?

        @conn[:embed_jobs].where(state: "running").order(:created_at).each do |row|
          begin
            resume!(row)
            result[:resumed] << row.fetch(:id)
          rescue StandardError => e
            # The resume is impossible (the re-enqueue failed — a dead wire,
            # a gone model): the row marks failed with the error pair
            # (ck_embed_jobs_error_pair) — the ledger never lies (I03).
            fail!(row, "orphaned running embed job could not resume: #{e.class}: " \
                       "#{e.message.to_s[0, 200]}")
            result[:failed] << row.fetch(:id)
          end
        end
        result
      end

      private

      # A live job-worker heartbeat exists → the running rows are claimed;
      # sweep is a no-op (J-IDEM: complete rows never sweep either). (The
      # gone-model case cannot arise as a row state: fk_embed_jobs_model
      # pins the model row — an unroutable resume surfaces as the rescue
      # path above, not as a pre-check.)
      def job_worker_live?
        @registry.live_workers.any? { |w| w[:value]["kind"] == "job" }
      end

      # Resume from the `done_items` cursor: the row re-enters pending and is
      # re-enqueued (the pipeline's own push seam — the body restarts at the
      # `done_items` cursor; the idem key is the row's own, so J-IDEM holds).
      # Re-entering pending clears started_at (ck_embed_jobs_run_pair ties
      # started_at to the non-pending states); the done_items cursor survives.
      def resume!(row)
        @conn[:embed_jobs].where(id: row.fetch(:id), state: "running")
                          .update(state: "pending", started_at: nil)
        Kquest::Pipeline::Enqueue.push(row.fetch(:id), status: :resumed)
        nil
      end

      def fail!(row, note)
        now = Time.now
        @conn[:embed_jobs].where(id: row.fetch(:id), state: "running")
                          .update(state: "failed", ended_at: now, error_note: note)
        nil
      end
    end
  end
end
