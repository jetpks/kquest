#!/usr/bin/env ruby
# frozen_string_literal: true

# The HEADLESS phase run (I13 Part 6 — the frozen gate's subject): the engine
# is exercisable against the entry-2 schema BEFORE any HTTP surface exists —
# I04's design intent. Standalone (like script/live_embed_smoke.rb); runs
# HANAMI_ENV=test; KEYLESS — it starts its OWN in-process
# MockCompletionsServer (the mock IS the wire; no live call of any kind).
#
# The run: mints tenancy (user/quest/phase via Sequel — the pipeline-fixtures
# pattern), upserts an `llm_providers` row pointing at the mock, scripts a
# phase — turn 1 `:tool_use` (a script-local tool that inserts a claims row
# THROUGH the harness's same-transaction audit), turn 2 `:text` final —
# cold-boots the session via SessionSupervisor, runs the LoopDriver under a
# scripted phase contract (max turns, terminal on the no-tool stop), then
# SELF-VERIFIES against the durable state. On success it prints the
# observable markers then HEADLESS_RUN_OK (rc 0); any failing check prints
# HEADLESS_RUN_FAILED + the check name (rc 1).

require "bundler/setup"
require "hanami/prepare"
require "fast/completions"
require "kernel/sync"
require_relative "../test/support/mock_completions_server"

def fail_run!(check)
  puts "HEADLESS_RUN_FAILED"
  puts "FAILED_CHECK #{check}"
  exit 1
end

conn = Kquest::App["db.gateway"].connection
mock = MockCompletionsServer.new.start

# ---- tenancy (the pipeline-fixtures mint; reruns safe — fresh uuids) -------
user_id = conn[:users].insert(handle: "headless-#{SecureRandom.hex(6)}",
                              github_uid: SecureRandom.uuid,
                              username: "u#{SecureRandom.hex(6)}", name: "Headless Run")
quest_id = conn[:quests].insert(user_id: user_id, topic: "I13 headless engine run",
                                web_call_budget: 0, token_budget: 1_000_000,
                                spend_budget_usd: 1.0)
phase_id = conn[:phases].insert(user_id: user_id, quest_id: quest_id, kind: "decompose")

# ---- the provider row (config data, upserted by THIS run — never seeded) ---
conn[:llm_providers].where(name: "headless-run-provider").delete
conn[:llm_providers].insert(name: "headless-run-provider", base_url: mock.url,
                            api_key_ref: nil, model_id: "headless-run-model",
                            context_window: 8192, max_tokens: 512, reasoning: false,
                            max_retries: 0)
provider_row = conn[:llm_providers].where(name: "headless-run-provider").first

# ---- the phase script: turn 1 tool_use, turn 2 text final ------------------
CLAIM_TEXT = "the headless run's claim, minted through the harness's same-transaction audit"

class HeadlessClaimTool < Fast::Completions::Tool
  description "mints a claim row (the run's single mutation)"
  tool_name "claim_writer"
  parameters { {"type" => "object",
                "properties" => {"text" => {"type" => "string"}},
                "required" => ["text"]} }

  attr_writer :conn, :user_id, :quest_id

  def mutates? = true

  def execute(text:, **_rest)
    seq = (@conn[:claims].where(quest_id: @quest_id).max(:quest_seq) || 0) + 1
    # the DR-06 quest-salted URN (the fixture law's own recipe)
    urn = "kb:claim:" + Kquest::Pipeline::Base58
      .encode(Digest::SHA256.digest(@quest_id + text))[0, 10]
    claim_id = @conn[:claims].insert(user_id: @user_id, quest_id: @quest_id, quest_seq: seq,
                                     text: text, urn: urn)
    {claim_id: claim_id}
  end
end

tool = HeadlessClaimTool.new
tool.conn = conn
tool.user_id = user_id
tool.quest_id = quest_id
mock.script([
  {type: :tool_use, tool_calls: [{id: "headless-call-1", name: "claim_writer",
                                  arguments: {text: CLAIM_TEXT}}]},
  {type: :text, content: "the claim is minted; the phase's scripted work is complete"}
])

# ---- the cold boot + the loop ----------------------------------------------
session_id = nil
desk = nil
run_ledger_bytes = 0
begin
  Sync do
    supervisor = Kquest::Engine::SessionSupervisor.new(conn: conn)
    boot = supervisor.cold_boot(quest_id: quest_id) # L7: store-backed reads ONLY
    fail_run!("cold_boot_views") unless boot.is_a?(Hash)

    session_id = supervisor.launch(user_id: user_id, quest_id: quest_id, phase_id: phase_id,
                                   mode: "autonomous", driver: "orchestrator",
                                   model: provider_row[:model_id])
    session = {id: session_id, user_id: user_id, quest_id: quest_id, phase_id: phase_id,
               model: provider_row[:model_id]}

    config = Kquest::Engine.config(conn)
    desk = Kquest::Engine::ProviderDesk.new(conn: conn, provider_row: provider_row,
                                            session: session)
    ledger = Kquest::Engine::TranscriptLedger.new(conn: conn, session: session)
    budgeter = Kquest::Engine::ContextBudgeter.new(conn: conn, session: session, desk: desk,
                                                   config: config)
    watch = Kquest::Engine::StreamWatch.new(conn: conn, session: session, config: config)
    governor = Kquest::Engine::RetryGovernor.new(conn: conn, config: config,
                                                 supervisor: supervisor, sleeper: ->(s) { sleep s })
    harness = Kquest::Engine::ToolHarness.new(conn: conn, session: session, ledger: ledger,
                                              config: config,
                                              write_guard: supervisor.write_guard_for(session),
                                              budgeter: budgeter)
    contract = Object.new
    contract.define_singleton_method(:assemble_context) do |turn|
      {instructions: "the headless phase: mint one claim, then finish", messages: []}
    end
    contract.define_singleton_method(:terminal?) do |turn:, chat:|
      chat.complete? && turn >= 1 # terminal on the no-tool stop
    end
    contract.define_singleton_method(:max_turns) { 4 }

    driver = Kquest::Engine::LoopDriver.new(conn: conn, desk: desk, harness: harness,
                                            ledger: ledger, budgeter: budgeter, watch: watch,
                                            governor: governor, supervisor: supervisor,
                                            contract: contract, config: config,
                                            tools: [tool])
    driver.run
    run_ledger_bytes = ledger.bytes
  end

  # ---- the self-verification (against the DURABLE state) -------------------
  claim = conn[:claims].where(quest_id: quest_id).first
  fail_run!("claims_row") unless claim && claim[:text] == CLAIM_TEXT

  audit = conn[:tool_calls].where(session_id: session_id, tool: "claim_writer").first
  fail_run!("tool_calls_audit_row_same_transaction") unless audit && audit[:ok]

  usage_rows = conn[:usage_events].where(session_id: session_id, kind: "llm").all
  fail_run!("usage_rows_one_per_turn") unless usage_rows.size == 2
  fail_run!("usage_seed_column") unless usage_rows.all? { |r| r[:seed].is_a?(Integer) }

  blob_key = conn[:sessions].where(id: session_id).get(:transcript_blob_key)
  fail_run!("transcript_blob_key_check_regex") unless blob_key =~ /\Asessions\/[0-9a-f-]{36}\/transcript\.jsonl\z/
  fail_run!("transcript_nonempty") unless run_ledger_bytes > 0

  fail_run!("quest_state_untouched") unless conn[:quests].where(id: quest_id).get(:state) == "active"
  fail_run!("no_pause_ledgered") unless conn[:quest_lifecycle_events].where(quest_id: quest_id).count.zero?

  # ---- the observable markers ------------------------------------------------
  puts "SESSION #{session_id}"
  puts "TURNS 2"
  puts "TOOL_CALLS #{conn[:tool_calls].where(session_id: session_id).count}"
  puts "USAGE_ROWS #{usage_rows.size}"
  puts "TRANSCRIPT_BYTES #{run_ledger_bytes}"
  puts "PHASE_DONE"
  puts "HEADLESS_RUN_OK"
ensure
  mock.stop
  desk&.close
end
