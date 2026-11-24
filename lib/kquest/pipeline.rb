# frozen_string_literal: true

module Kquest
  # The fetch→chunk→embed job worker (I12): idempotent by the ledger's
  # idem-key law, resumable from the durable `done_items` cursor, J-SPEND
  # wired both directions in one transaction. Every write path goes through
  # ONE Sequel connection (injectable as `conn:` — fork-safety); the ROM
  # relations/repos remain the read layer for consumers. Every refusal is a
  # Pipeline::Error whose message lands in the job row's error_note.
  module Pipeline
  end
end
