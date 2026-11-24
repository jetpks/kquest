# frozen_string_literal: true

require "fast/completions"

module Kquest
  # The native agent loop (I04 §2.1's ten components + the seed decorator,
  # I13). Every component is constructor-injected (`conn:`, config readers) —
  # never a global. Every refusal raises `Kquest::Engine::Error` with a
  # message carrying the violated rule AND the legal alternative
  # (refusals-that-teach). No provider/model name literal appears anywhere in
  # this subsystem: `llm_providers` rows are the only provider path (G-REG).
  module Engine
    # The loop-wide caps/budget lines (I04 §2.5/§7 + DR-09). The FROZEN design
    # defaults — the same 15 keys config/db/seeds.rb seeds into
    # `engine_config`; the DB rows win over these when present, so a mutated
    # seed value heals at the next prepare and a component constructed
    # against an empty table still carries the design law.
    DEFAULT_CONFIG = {
      "engine.transport_retry_cap"           => 3,
      "engine.rate_limit_retry_cap"          => 5,
      "engine.server_error_retry_cap"        => 3,
      "engine.stream_retry_cap"              => 2,
      "engine.phase_attempt_cap"             => 3,
      "engine.tool_timeout_s"                => 120,
      "engine.subagent_timeout_s"            => 1800,
      "engine.subagent_status_poll_s"        => 30,
      "engine.unknown_tool_alert_at"         => 3,
      "engine.dropped_chunk_alert_threshold" => 3,
      "engine.slow_stall_bytes"              => 100,
      "engine.slow_stall_window_s"           => 1200,
      "engine.unattended_pause_s"            => 3600,
      "engine.read_slice_cap_chars"          => 8000,
      "engine.embed_retry_cap"               => 3
    }.freeze

    module_function

    # The engine config lines: {key => {value:, mode:}} — the DB's
    # `engine_config` rows over the frozen defaults. `mode` ∈ advisory|hard is
    # read ONLY by budget-guard consumers (DR-09: advisory by default,
    # toggleable to hard; retry caps never consult it).
    def config(conn)
      rows = conn[:engine_config].to_a
      defaults = DEFAULT_CONFIG.transform_values { |v| {value: v, mode: "advisory"} }
      defaults.merge(rows.to_h { |r| [r.fetch(:key), {value: r.fetch(:value), mode: r.fetch(:mode)}] })
    end

    # A config value as a plain number (numeric values arrive as BigDecimal).
    def config_value(lines, key)
      line = lines.fetch(key)
      value = line.fetch(:value)
      value.is_a?(Numeric) && !value.is_a?(Integer) && value.denominator == 1 ? value.to_i : value
    end
  end
end
