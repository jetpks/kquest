#!/usr/bin/env ruby
# frozen_string_literal: true

# DEV-ONLY single-process job worker. It dequeues job hashes from redis and
# runs the job body for each; stop with Ctrl-C (SIGINT) — the Async reactor's
# default SIGINT handling stops the scheduler and exits cleanly without
# explicit signal traps.
#
# One queue, one worker, many bodies: the delegate routes the embed
# pipeline's "embed_job_id" payloads through Kquest::Pipeline::Runner and
# everything else through the substrate's ProcessDocument example.
#
# This template deliberately carries NO supervised/managed worker topology —
# hosting this process in production (a supervisor, a container, a service
# host) is a decision each minted project makes for itself.
#
# Usage: REDIS_URL=redis://localhost:6379 mise exec -- bundle exec ruby bin/worker.rb

require "hanami/boot"
require "async"
require_relative "../lib/kquest/orchestrator"

server = Kquest::Jobs::Delegate.build_redis_processor

Console.logger.info(self, "Job worker starting (prefix=jobs)")
Console.logger.info(self, "Stop with Ctrl-C — dev-only worker; no managed topology in this template")

Async do
  # The job worker's OWN orphan sweep (I08 §2.3): the singleton class (DR-02)
  # makes the boot-time sweep honest — no live job-worker heartbeat exists
  # yet, so every `running` embed row is orphaned and resumes from
  # `done_items` (or marks failed with the error pair when the resume is
  # impossible). Repeated periodically alongside the dequeue loop.
  sweep_conn = Kquest::App["db.gateway"].connection
  sweep_registry = Kquest::Orchestrator::WorkerRegistry.new(redis: Kquest::App["redis"],
                                                            kind: "job")
  job_sweeper = Kquest::Orchestrator::JobSweeper.new(conn: sweep_conn, registry: sweep_registry)
  begin
    swept = job_sweeper.sweep
    Console.logger.info(self, "job sweep at boot: #{swept.inspect}")
  rescue StandardError => e
    Console.logger.error(self, "job sweep at boot failed: #{e.class}: #{e.message}")
  end
  sweep_registry.register!

  periodic_sweep = Async do
    loop do
      Async::Task.current.sleep(60)
      begin
        job_sweeper.sweep
      rescue StandardError => e
        Console.logger.error(self, "periodic job sweep failed: #{e.class}: #{e.message}")
      end
    end
  end

  server.start
  Async::Task.current.sleep
ensure
  periodic_sweep&.stop
  sweep_registry&.unregister!
end
