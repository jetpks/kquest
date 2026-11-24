#!/usr/bin/env ruby
# frozen_string_literal: true

# The QUEST-WORKER LAUNCHER (I08 DR-08 ruling A): a tiny periodic loop that
# keeps EXACTLY ONE `bin/quest-worker.rb` child per ACTIVE quest (registry-
# verified, never pidfile-guessed), reaps exited children, and hosts the
# assurance poller (one global pass per cadence — the cross-quest tripwire
# predicates fire once). Falcon supervises this process alongside the web
# service when the deploy env enables the worker topology (see falcon.rb).
#
# Usage: REDIS_URL=... DATABASE_URL=... mise exec -- bundle exec ruby bin/quest-worker-launcher.rb

require "hanami/boot"
require "async"
require_relative "../lib/kquest/orchestrator"

Sync do
  conn = Kquest::App["db.gateway"].connection
  redis = Kquest::App["redis"]

  registry = Kquest::Orchestrator::WorkerRegistry.new(redis: redis, kind: "launcher")
  poller = Kquest::Orchestrator::AssurancePoller.new(
    conn: conn, publisher: Kquest::Orchestrator::EventPublisher.new(redis: redis)
  )
  launcher = Kquest::Orchestrator::Launcher.new(conn: conn, registry: registry, poller: poller)
  registry.register!

  Console.logger.info(self, "quest-worker launcher starting (one worker per active quest)")
  launcher.run
end
