# frozen_string_literal: true

require "async"
require "kernel/sync"

module Kquest
  module Pipeline
    # The job runner: the Delegate's embed/chunk dispatch target. One pass,
    # no retry machinery — the caller's retry is a NEW job row sharing the
    # idem key. ANY StandardError from a body lands verbatim (truncated) in
    # the row's error_note — the ledger never lies, the cursor is kept.
    class Runner
      def initialize(conn: Kquest::App["db.gateway"].connection)
        @conn = conn
      end

      def call(job_id:)
        # The wire client is fiber-native: run inside the ambient reactor
        # when there is one, else a transient one (Sync no-ops in-reactor).
        if Async::Task.current?
          run(job_id)
        else
          Sync { run(job_id) }
        end
      end

      private

      def run(job_id)
        row = @conn[:embed_jobs].where(id: job_id).first
        return :noop unless row

        case row[:state]
        when "complete" then :noop
        when "failed" then :failed # terminal — a retry is a NEW row sharing the key
        when "pending", "running"
          dispatch(row)
        else
          State.mark_failed!(@conn, row, "embed job #{row[:id]}: unknown state #{row[:state].inspect}")
          :failed
        end
      end

      def dispatch(row)
        case row[:kind]
        when "embed"
          EmbedBody.new(conn: @conn).run(row)
          :complete
        when "chunk"
          ChunkBody.new(conn: @conn).run(row)
          :complete
        else
          # A fetch row on the queue fails loudly: the fetch body is the
          # web-op direct-call seam, never a queue body (rows are minted
          # complete by FetchBody).
          raise Error, "job kind #{row[:kind].inspect} is not a queue body — fetch rows are " \
                       "minted complete by the web-op direct-call seam and never ride the queue"
        end
      rescue StandardError => e
        State.mark_failed!(@conn, row, e.message)
        :failed
      end
    end
  end
end
