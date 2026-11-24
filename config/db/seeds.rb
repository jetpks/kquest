# Seed data — idempotent (delete+insert), run by `hanami db prepare` on
# EVERY prepare (self-healing: the db always mirrors the seed files below,
# so a mutated seed value is healed at the next prepare and the
# seed-contract gate bites).
#
# Contracts carried here:
#   - The two I06 quest-process TSVs are CONFIG DATA: the app ships its own
#     byte-exact copies (config/db/seeds/*.tsv — cmp'd against design/ by
#     the config-parity gate); the rows land in `phase_transitions` /
#     `stop_rules` in FILE ORDER, nothing re-encoded, no logic beyond the
#     header assertion + the insert.
#   - The D4 first model registration: bge-m3 via OpenRouter with the I03
#     fixture's fixed uuid `92000000-0000-4000-8000-000000000001`
#     (REQUIRED — `emb_bge_m3_1024`'s CHECK literal pins that uuid).
#     `api_key_ref` is a credential REFERENCE (`env:OPENROUTER_API_KEY` —
#     the I03 DR-07 law's own example form), never key material.
#   - The day-one chunk strategy: `para-800` (I03 §6).
#   - The I13 engine config (I04 §2.5/§7 + DR-09): the 15 loop caps/budget
#     lines with the FROZEN design default values (provenance cites the FM
#     row / design §), advisory by default (DR-09 as ruled); and the two
#     day-one `subagent_profiles` rows VERBATIM from I05 §8 (survey
#     read-only, operator the full 24-tool surface). NO `llm_providers` row
#     is seeded: provider rows are operator/session-minted config.

config_dir = File.expand_path(__dir__)
seeds_dir  = File.join(config_dir, "seeds")

conn = Kquest::App["db.gateway"].connection

# --- phase_transitions (27 rows, file order = ordinal 1..27) -----------------
transitions_header = %w[from_phase event guard to_phase phase_kind_exit evidence]
transitions_lines  = File.readlines(File.join(seeds_dir, "transitions.tsv"), chomp: true)
header = transitions_lines.shift&.split("\t", -1)
unless header == transitions_header
  raise "config/db/seeds/transitions.tsv header drift: #{header.inspect} (expected #{transitions_header.inspect})"
end

conn.transaction do
  conn[:phase_transitions].delete
  transitions_lines.each_with_index do |line, i|
    from_phase, event, guard, to_phase, phase_kind_exit, evidence = line.split("\t", -1)
    conn[:phase_transitions].insert(
      ordinal:         i + 1,
      from_phase:      from_phase,
      event:           event,
      guard:           guard,
      to_phase:        to_phase,
      phase_kind_exit: phase_kind_exit,
      evidence:        evidence
    )
  end
end

# --- stop_rules (19 rows, file order = rule_id order) ------------------------
stop_rules_header = %w[rule_id scope metric default operator action provenance config_key]
stop_rules_lines  = File.readlines(File.join(seeds_dir, "stop-rules.tsv"), chomp: true)
header = stop_rules_lines.shift&.split("\t", -1)
unless header == stop_rules_header
  raise "config/db/seeds/stop-rules.tsv header drift: #{header.inspect} (expected #{stop_rules_header.inspect})"
end

conn.transaction do
  conn[:stop_rules].delete
  stop_rules_lines.each do |line|
    rule_id, scope, metric, default, operator, action, provenance, config_key = line.split("\t", -1)
    conn[:stop_rules].insert(
      rule_id:    rule_id,
      scope:      scope,
      metric:     metric,
      default:    default,
      operator:   operator,
      action:     action,
      provenance: provenance,
      config_key: config_key
    )
  end
end

# --- the D4 first model registration (delete+insert by id, self-healing) ----
conn[:embedding_models].where(id: "92000000-0000-4000-8000-000000000001").delete
conn[:embedding_models].insert(
  id:              "92000000-0000-4000-8000-000000000001",
  slug:            "bge-m3-1024",
  wire_name:       "bge-m3",
  provider:        "openrouter",
  endpoint:        "https://openrouter.ai/api/v1/embeddings",
  api_key_ref:     "env:OPENROUTER_API_KEY",
  dimensions:      1024,
  metric:          "cosine",
  batch_max_texts: 64,
  input_max_chars: 8192,
  status:          "active",
  table_name:      "emb_bge_m3_1024"
)

# --- engine_config (15 frozen design defaults, I04 §2.5/§7 + DR-09) ---------
ENGINE_CONFIG_DEFAULTS = {
  "engine.transport_retry_cap"           => [3, "FM-05/06/15 (I04 §2.5 L1)"],
  "engine.rate_limit_retry_cap"          => [5, "FM-07 (I04 §2.5 L1/L3)"],
  "engine.server_error_retry_cap"        => [3, "FM-08 (I04 §2.5 L1)"],
  "engine.stream_retry_cap"              => [2, "FM-13 (I04 §2.5 L1)"],
  "engine.phase_attempt_cap"             => [3, "FM-01 (the PoC's discovered RETRY_CAP=3)"],
  "engine.tool_timeout_s"                => [120, "FM-04 (I04 §2.5 wedge guards)"],
  "engine.subagent_timeout_s"            => [1800, "FM-20 (I04 §6 spawn discipline)"],
  "engine.subagent_status_poll_s"        => [30, "FM-20 (I04 §6 spawn discipline)"],
  "engine.unknown_tool_alert_at"         => [3, "FM-12 (consecutive unknown-tool wedge guard)"],
  "engine.dropped_chunk_alert_threshold" => [3, "FM-14 (tolerant inbound stream)"],
  "engine.slow_stall_bytes"              => [100, "FM-18 (SLOWSTALL alert, StreamWatch)"],
  "engine.slow_stall_window_s"           => [1200, "FM-18 (SLOWSTALL alert, StreamWatch)"],
  "engine.unattended_pause_s"            => [3600, "FM-18 (unattended window → pause, never kill)"],
  "engine.read_slice_cap_chars"          => [8000, "FM-22 (ContextBudgeter accounting cap; the read-tool refusal is I05 R-052)"],
  "engine.embed_retry_cap"               => [3, "FM-23 (the shared embed retry classes)"]
}.freeze

conn.transaction do
  ENGINE_CONFIG_DEFAULTS.each do |key, (value, provenance)|
    conn[:engine_config].where(key: key).delete
    conn[:engine_config].insert(key: key, value: value, mode: "advisory", provenance: provenance)
  end
end

# --- subagent_profiles (the two day-one profiles, I05 §8 verbatim) ----------
SURVEY_TOOLS = %w[status mass node_get neighbors search list paths
                  source_read source_grep source_list retrieve].freeze
OPERATOR_TOOLS = %w[node_add node_set node_get edge_add frontier_add frontier_close
                    status search list paths mass neighbors source_read source_grep
                    source_list web_search web_fetch retrieve report_draft report_bind
                    harness quest_status subagent_spawn subagent_status].freeze

conn.transaction do
  {
    "survey"   => SURVEY_TOOLS,
    "operator" => OPERATOR_TOOLS
  }.each do |name, tools|
    conn[:subagent_profiles].where(name: name).delete
    conn[:subagent_profiles].insert(
      name: name, tools: JSON.generate(tools),
      provenance: "I05 §8 / I04 DR-08 (profiles are config data; the registration IS the restriction)"
    )
  end
end

# --- the para-800 day-one chunk strategy (delete+insert by (name, version)) --
require "json" # subagent_profiles.tools is jsonb

conn[:chunk_strategies].where(name: "para-800", version: 1).delete
conn[:chunk_strategies].insert(
  name:              "para-800",
  version:           1,
  target_chars:      800,
  overlap_chars:     0,
  paragraph_aligned: true
)
