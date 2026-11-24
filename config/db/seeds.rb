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

# --- the para-800 day-one chunk strategy (delete+insert by (name, version)) --
conn[:chunk_strategies].where(name: "para-800", version: 1).delete
conn[:chunk_strategies].insert(
  name:              "para-800",
  version:           1,
  target_chars:      800,
  overlap_chars:     0,
  paragraph_aligned: true
)
