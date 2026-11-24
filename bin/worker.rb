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

server = Kquest::Jobs::Delegate.build_redis_processor

Console.logger.info(self, "Job worker starting (prefix=jobs)")
Console.logger.info(self, "Stop with Ctrl-C — dev-only worker; no managed topology in this template")

Async do
  server.start
  Async::Task.current.sleep
end
