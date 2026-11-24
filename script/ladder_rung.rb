#!/usr/bin/env ruby
# frozen_string_literal: true

# The LADDER RUNG harness (I07 §7; I08 §10): `script/ladder_rung.rb
# <probe|smoke|partial|full> [--live] [--passed-by <who>]`.
#
# Every rung mints its scenario, runs its work through the REAL engine + REAL
# tools, evaluates its gate per the §7 table, and on PASS writes one
# `ladder_passes` row. KEYLESS LAW: without `--live` the rung runs against the
# in-process mock wires and prints LADDER_RUNG_OK (a machinery proof — the
# mock IS the wire); the live leg requires the named key path and LOUD-SKIPS
# keyless (`LADDER_RUNG_SKIPPED_NO_KEY`, exit 0 with the skip marker — the
# recalibration pattern; never a silent pass, never fabricated numbers).
# Any failing gate prints LADDER_RUNG_FAILED + the reason (rc 1).

require "bundler/setup"
require "hanami/prepare"
require "kernel/sync"
# The rung's fixture mint (the Ladder's build_rig/teardown_rig reference
# OrchestratorFixtures — a test-support constant, loadable standalone only
# through this pre-load; the test files require it themselves).
require_relative "../test/support/orchestrator_fixtures"
require_relative "../lib/kquest/orchestrator/ladder"

rung = ARGV.shift
unless Kquest::Orchestrator::Ladder::RUNGS.include?(rung)
  warn "usage: script/ladder_rung.rb <probe|smoke|partial|full> [--live] [--passed-by <who>]"
  exit 1
end
live = ARGV.delete("--live")
passed_by = ARGV.each_cons(2).find { |(flag, _)| flag == "--passed-by" }&.last || "ladder-runner"

def fail_rung!(reason)
  puts "LADDER_RUNG_FAILED #{reason}"
  exit 1
end

if live
  # The live leg's key path: the recalibration pattern — a key PATH env (the
  # credential REFERENCE form, never key material in-tree). Keyless here →
  # the loud skip.
  key_path = ENV["LADDER_LIVE_KEY_PATH"]
  if Kquest::Orchestrator::Ladder.live_key_missing?(key_path)
    puts "LADDER_RUNG_SKIPPED_NO_KEY #{rung} (the live leg requires LADDER_LIVE_KEY_PATH; " \
         "the mock-wire machinery proof is `script/ladder_rung.rb #{rung}`)"
    exit 0
  end
  fail_rung!("the live leg needs a real serving stack — not wired keyless by design")
end

conn = Kquest::App["db.gateway"].connection

if rung == "full"
  # The earlier mock-wire rungs' fixture cleanup sweeps the GLOBAL config
  # tables (the standing law re-heals them at the next `hanami db prepare`
  # — this rung may be the next thing run); the full rung's phase contract
  # reads the SEEDED phase_task_text rows, so it re-heals by re-running the
  # seeds file's own idempotent delete+inserts (never re-encoded here).
  load(File.expand_path("../config/db/seeds.rb", __dir__))
end

ladder = Kquest::Orchestrator::Ladder.new(conn: conn, passed_by: passed_by)

begin
  Sync do
    evidence_ref = ladder.public_send(rung)
    puts "RUNG #{rung}"
    puts "EVIDENCE #{evidence_ref.is_a?(String) ? evidence_ref : ladder.evidence.keys.map(&:to_s).join(',')}"
    puts "LADDER_RUNG_OK #{rung}"
  end
rescue Kquest::Orchestrator::Ladder::GateFailure => e
  fail_rung!(e.message)
ensure
  ladder.mocks.each(&:stop)
end
