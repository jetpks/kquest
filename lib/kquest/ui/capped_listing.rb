# frozen_string_literal: true

module Kquest
  module Ui
    # The L15 capped listing (BRIEF §3: principled ordering + caps on EVERY
    # listing surface; "what the agent never saw" is measurable). Given a
    # Sequel dataset + `surface:`, applies the caller-declared PRINCIPLED,
    # deterministic ORDER, then the cap from the `tool_config` row
    # `ui.listing_cap.<surface>` (config is the only cap source — never a
    # hardcoded literal), and emits the per-request telemetry row
    # (CapRecords.record!) in the SAME transaction as the read.
    #
    # Returns {rows:, requested:, cap:, existed:} — when `requested > cap` the
    # caller MUST surface "showing N of M" (never silent truncation; the page
    # renders it from these fields).
    module CappedListing
      module_function

      def call(conn, dataset, surface:, user_id:, quest_id: nil, order: nil)
        cap = cap_for(conn, surface)
        requested = dataset.count
        ordered = order ? dataset.order(*order) : dataset
        rows = ordered.limit(cap).to_a

        conn.transaction do
          CapRecords.record!(conn, user_id: user_id, surface: surface, quest_id: quest_id,
                             requested: requested, cap: cap, existed: requested)
        end

        {rows: rows, requested: requested, cap: cap, existed: requested}
      end

      # The lane-authored defaults for the FROZEN surface names (the values
      # mirror config/db/seeds.rb's ui.listing_cap rows). The engine's
      # DEFAULT_CONFIG precedent (lib/kquest/engine.rb): the DB rows win over
      # these when present, so a mutated seed value heals at the next prepare,
      # and a component constructed against an empty table (the suite's
      # teardowns wipe tool_config) still carries the L15 cap law.
      DEFAULT_CAPS = {
        "dashboard" => 50, "quest" => 50, "frontier" => 50, "graph" => 50,
        "reports" => 50, "costs" => 100, "alerts" => 20,
        "workspace_admin" => 50
      }.freeze

      # The cap from config (the I15 lane-authored-constants precedent:
      # `verification.spot_check_n`, `assurance.poll_interval_s` are
      # tool_config rows). A missing row falls back to the lane-authored
      # default (never an uncapped listing); an UNKNOWN surface is LOUD.
      def cap_for(conn, surface)
        key = "ui.listing_cap.#{surface}"
        row = conn[:tool_config].where(key: key).first
        return Integer(row.fetch(:num_value)) if row

        raise ArgumentError, "no L15 cap for surface #{surface.inspect} — " \
                             "ui.listing_cap.<surface> is the only cap source" \
          unless DEFAULT_CAPS.key?(surface)

        DEFAULT_CAPS.fetch(surface)
      end
    end
  end
end
