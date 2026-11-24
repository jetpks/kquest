# frozen_string_literal: true

module Kquest
  module Engine
    # The engine's only error type: every refusal raises this; messages carry
    # the violated rule AND the legal alternative (refusals-that-teach). The
    # gem's CancelledError stands OUTSIDE its own Error tree (D8) — a rescue
    # of this class never swallows a cancellation. `error_class` is the audit
    # classification for harness-level refusals (ToolDeadline, WriteGuard,
    # ...); plain refusals default to EngineRefusal.
    class Error < StandardError
      attr_reader :error_class

      def initialize(message = nil, error_class: "EngineRefusal")
        super(message)
        @error_class = error_class
      end
    end
  end
end
