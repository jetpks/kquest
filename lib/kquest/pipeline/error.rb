# frozen_string_literal: true

module Kquest
  module Pipeline
    # The pipeline's only error type: every refusal (admission control, a
    # retired registry row, a missing session, a malformed wire reply) raises
    # this; the Runner lands its message verbatim in the job row's
    # error_note — refusals-that-teach.
    class Error < StandardError; end
  end
end
