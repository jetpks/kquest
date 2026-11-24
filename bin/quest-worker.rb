#!/usr/bin/env ruby
# frozen_string_literal: true

# The QUEST WORKER process (I08 §2.1, DR-02 ruling A): one process per ONE
# active quest — `bin/quest-worker.rb <quest_id>`. Boots cold (L7), registers
# in the redis worker registry, hosts the phase runner + the transcript
# watcher + the ledger projector + the reaper pass, and EXITS when the quest
# leaves `active` (exit is safe: nothing is live; resume is a fresh worker).
# The launcher (`bin/quest-worker-launcher.rb`) keeps exactly one of these
# alive per active quest; falcon supervises the launcher when the deploy env
# enables the worker topology (see falcon.rb).
#
# The assurance poller is NOT hosted here: the launcher hosts it (the
# cross-quest predicates fire once globally).
#
# Usage: REDIS_URL=... DATABASE_URL=... mise exec -- bundle exec ruby bin/quest-worker.rb <quest_id>

require "hanami/boot"
require "async"
require_relative "../lib/kquest/orchestrator"

quest_id = ARGV[0]
unless quest_id
  warn "usage: bin/quest-worker.rb <quest_id>"
  exit 1
end

Sync do
  conn = Kquest::App["db.gateway"].connection
  redis = Kquest::App["redis"]

  registry = Kquest::Orchestrator::WorkerRegistry.new(redis: redis, kind: "quest",
                                                      quest_id: quest_id)
  supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn, liveness: registry)
  publisher = Kquest::Orchestrator::EventPublisher.new(redis: redis)
  watcher = Kquest::Orchestrator::TranscriptWatcher.new(
    quest_id: quest_id, publisher: publisher, config: Kquest::Engine.config(conn)
  )
  projector = Kquest::Orchestrator::LedgerProjector.new(conn: conn, publisher: publisher)
  runner = Kquest::Orchestrator::PhaseRunner.new(conn: conn, supervisor: supervisor,
                                                 publisher: publisher, registry: registry,
                                                 watcher: watcher)
  worker = Kquest::Orchestrator::QuestWorker.new(conn: conn, quest_id: quest_id,
                                                 registry: registry, supervisor: supervisor,
                                                 runner: runner, watcher: watcher,
                                                 projector: projector)
  verdict = worker.run
  Console.logger.info(self, "quest worker exiting: #{verdict}")
end
