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
#   - The I14 tool config (I05 DR-09's caps + D4/I03 G-REG claim-model ref +
#     the CALIBRATED dedup constants): `tool_config` rows, one value carrier
#     per row. The two dedup rows' values are the live recalibration run's
#     chosen constants — provenance cites the committed run record
#     (script/dedup_calibration/record.md); I05 DR-07 ruling A made the
#     pre-calibration values (k=5 / floor 0.6) provisional.
#   - The I15 orchestrator rows (arc ENTRY 4, Part 12): the five phase-kind
#     task texts (the phase prompt's first part — transcribed from the I06
#     §9 Task lines, provenance citing the §), `verification.spot_check_n`
#     (I07 DR-02 ruling A) and `assurance.poll_interval_s` (I08 §3.4
#     default). No engine_config change; no seeded provider rows (tests +
#     scripts upsert their own — the standing law).
#   - The ONE existing-seed-line change (I05 DR-04 operator ruling A,
#     amending I04 DR-09 for this single line): `engine.read_slice_cap_chars`
#     ships mode=hard — the frozen `non-sliced-read` refusal is the
#     hard-mode shape; every other line stays advisory.
#   - NO `web_providers` row is seeded: no live web provider exists day one;
#     the web tools refuse loudly naming the `tools.web_provider` config key
#     until an operator mints a row.

config_dir = File.expand_path(__dir__)
seeds_dir  = File.join(config_dir, "seeds")

require "json" # subagent_profiles.tools / tool_config are jsonb-adjacent inserts

# The calibrated dedup constants (I05 DR-07 ruling A / I14 Part 6): the values
# the live recalibration run chose — see the committed run record
# script/dedup_calibration/record.md (the seeds' provenance cites it).
# Live run 2026-11-24: floor 0.8387 (0 misclassifications over the 42-pair
# dataset, families non-overlapping), k 2.
CALIBRATED_K = 2
CALIBRATED_FLOOR = 0.8387

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
# {key => [value, provenance, mode]} — mode present ONLY for the read_slice
# line (I05 DR-04 ruling A: the ONE hard line); every other line advisory.
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
  "engine.read_slice_cap_chars"          => [8000, "FM-22 (ContextBudgeter accounting cap; the read-tool refusal is I05 R-052; mode HARD per I05 DR-04 operator ruling A)", "hard"],
  "engine.embed_retry_cap"               => [3, "FM-23 (the shared embed retry classes)"]
}.freeze

conn.transaction do
  ENGINE_CONFIG_DEFAULTS.each do |key, (value, provenance, mode)|
    conn[:engine_config].where(key: key).delete
    conn[:engine_config].insert(key: key, value: value, mode: mode || "advisory", provenance: provenance)
  end
end

# --- tool_config (the I05 tool caps + the claim-model ref + the CALIBRATED
# --- dedup constants; values from the committed recalibration record) -------
# {key => [num_value, text_value, provenance]} — exactly one value carrier.
TOOL_CONFIG_DEFAULTS = {
  "tools.cap_search_rows"          => [20, nil, "I05 DR-09 (tart's measured caps: search 20 rows / 120-char snippets)"],
  "tools.cap_search_snippet_chars" => [120, nil, "I05 DR-09 (tart's measured caps: search 20 rows / 120-char snippets)"],
  "tools.cap_list_rows"            => [50, nil, "I05 DR-09 (list 50 rows; source_list 50 rows)"],
  "tools.cap_neighbors"            => [50, nil, "I05 DR-09 (neighbors 50 aliases)"],
  "tools.cap_paths_depth"          => [128, nil, "I05 DR-09 (paths depth 128, tart §PATHS_DEPTH_CAP)"],
  "tools.cap_source_list_rows"     => [50, nil, "I05 DR-09 (source_list 50 rows)"],
  "tools.cap_report_section_chars" => [20_000, nil, "I05 DR-09 / fixtures (section-too-large: bodies capped at 20000 chars)"],
  "tools.claim_embedding_model"    => [nil, "92000000-0000-4000-8000-000000000001",
                                       "D4 first model registration + I03 G-REG (the registry is the only model path)"],
  "tools.dedup_near_top_k"         => [CALIBRATED_K, nil,
                                       "I05 DR-07 ruling A + I03 DR-15 — CALIBRATED against the real registry model; " \
                                       "run record: script/dedup_calibration/record.md"],
  "tools.dedup_near_floor"         => [CALIBRATED_FLOOR, nil,
                                       "I05 DR-07 ruling A + I03 DR-15 — CALIBRATED against the real registry model; " \
                                       "run record: script/dedup_calibration/record.md"]
}.freeze

conn.transaction do
  TOOL_CONFIG_DEFAULTS.each do |key, (num_value, text_value, provenance)|
    conn[:tool_config].where(key: key).delete
    conn[:tool_config].insert(key: key, num_value: num_value, text_value: text_value,
                              provenance: provenance)
  end
end

# --- the I15 orchestrator rows (additive, Part 12) ---------------------------
# The phase-kind task texts (I06 §9's Task lines, verbatim per § — the
# phase prompt's FIRST part; I06 §10.1) + the two assurance/verification
# constants (I07 DR-02 ruling A / I08 §3.4 default).
PHASE_TASK_TEXTS = {
  "phase_task_text.decompose" =>
    [nil,
     "Take one or more corpus sources with no evidence nodes yet: extract " \
     "verbatim-anchored evidence and claim nodes and seed the frontier.",
     "I06 §9.1 (the decompose Task line; mode-conditioned per I06 §10.1)"],
  "phase_task_text.frontier-build" =>
    [nil,
     "Enumerate the topic's clusters against the listing surface; create " \
     "evidence-anchored queued claims + frontier entries with needs naming " \
     "primaries (authors/year/venue) until the MASS floor is met.",
     "I06 §9.2 (the frontier-build Task line; mass-based, not count-based)"],
  "phase_task_text.descent" =>
    [nil,
     "Take the top open frontier item: resolve its descent need (from the " \
     "saved corpus when the target is already saved, else search and fetch " \
     "it), decompose the target, wire derives_from, type terminals, update " \
     "the frontier.",
     "I06 §9.3 (the descent Task line)"],
  "phase_task_text.synthesis" =>
    [nil,
     "Write the report FROM THE GRAPH (question-shaped chapters — the facet " \
     "law, mode-conditioned; every material claim cited with local ordinals; " \
     "imports explicitly marked, never silent, R-026/R-027).",
     "I06 §9.4 (the synthesis Task line; context is CONSTRUCTED, never " \
     "inherited — I02 DR-11)"],
  "phase_task_text.verification" =>
    [nil,
     "Path-checking (sample derivation paths; every assertion's path reaches " \
     "a typed terminal or an explicit uncertainty flag) + spot checks (spans " \
     "byte-exact vs blobs; readings faithful to their spans).",
     "I06 §9.5 (the verification Task line; I07 DR-01 ruling A cadence)"],
  "verification.spot_check_n" =>
    [20, nil, "I07 DR-02 ruling A (fixed n = 20, seeded, stratified per " \
              "verification phase)"],
  "assurance.poll_interval_s" =>
    [30, nil, "I08 §3.4 default (the assurance_alert poller cadence)"],
  "tools.web_search_cap" =>
    [5, nil, "I05 §7.1 (the web_search default max_results; the I15 scripted " \
             "quest's fixture wire)"],
  "tools.report_section_chars_cap" =>
    [20_000, nil, "I06 §9.4 write-in-sections (the I15 scripted quest's " \
                  "synthesis sectioning; mirrors tools.cap_report_section_chars)"]
}.freeze

conn.transaction do
  PHASE_TASK_TEXTS.each do |key, (num_value, text_value, provenance)|
    conn[:tool_config].where(key: key).delete
    conn[:tool_config].insert(key: key, num_value: num_value, text_value: text_value,
                              provenance: provenance)
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

conn[:chunk_strategies].where(name: "para-800", version: 1).delete
conn[:chunk_strategies].insert(
  name:              "para-800",
  version:           1,
  target_chars:      800,
  overlap_chars:     0,
  paragraph_aligned: true
)
