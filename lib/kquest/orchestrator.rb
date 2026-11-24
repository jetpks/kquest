# frozen_string_literal: true

module Kquest
  # The orchestrator (arc ENTRY 4 / I08 §2): the quest worker process + phase
  # runner wired over the landed I13 engine and I14 tools. The runner is a
  # PURE CONFIG CONSUMER — it EVALUATES the landed `phase_transitions` /
  # `stop_rules` tables (never encodes a transition; I06 §14), the launch
  # gate goes live over the redis worker registry (I04 DR-05), and the
  # signal path (watcher, poller) DETECTS and SIGNALS — never binds
  # (the eval-not-binding law, standing lesson #3).
  module Orchestrator
  end
end
