# frozen_string_literal: true

require "async/job/processor/redis"
require "async/redis"
require "async/redis/endpoint"

module Kquest
  module Jobs
    # The ONE job-system delegate (I08 DR-08: one queue, one worker, many
    # bodies). Routes by payload key: the embed pipeline's rows ride
    # "embed_job_id"; anything else stays the substrate's ProcessDocument
    # example (its "document_id" routing is unchanged — its suite test stays
    # green through this delegate).
    class Delegate
      def call(job)
        if job.key?("embed_job_id")
          Kquest::Pipeline::Runner.new.call(job_id: job["embed_job_id"])
        else
          ProcessDocument.new.call(job["document_id"])
        end
      end

      def start; end

      def stop; end

      # Build a Processor::Redis over THIS delegate — the ProcessDocument
      # construction, verbatim. Used by bin/worker.rb and the redis
      # integration test's shape: same construction in both.
      #
      # parent: nil → Server uses Async::Idler (correct for the long-running
      # worker process); parent: task → Server tasks become children of task
      # (needed in tests for clean teardown).
      def self.build_redis_processor(endpoint: nil, prefix: "jobs", parent: nil)
        ep = endpoint || begin
          url = ENV["REDIS_URL"]
          url ? Async::Redis::Endpoint.parse(url) : Async::Redis.local_endpoint
        end
        opts = {endpoint: ep, prefix: prefix}
        opts[:parent] = parent if parent
        Async::Job::Processor::Redis.new(Delegate.new, **opts)
      end
    end
  end
end
