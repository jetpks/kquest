# frozen_string_literal: true

module Kquest
  module Ui
    # The cap-telemetry ledger (I08 §2.5): ONE row per capped listing request,
    # written in the SAME transaction as the read (CapRecords.record! is called
    # from Kquest::UI::CappedListing inside its transaction). The rollup
    # (overhang_by_surface) feeds the dashboard's blind-spot panel (I07 §6) and
    # the frontier inspector's overhang badge — measurement only: nothing
    # reads these rows to throttle or block anything.
    module CapRecords
      module_function

      # One telemetry row. `quest_id` is optional (cross-quest listings, e.g.
      # the dashboard). Callers already inside a transaction: the row lands in
      # THEIR transaction; CappedListing opens its own when none is open.
      def record!(conn, user_id:, surface:, requested:, cap:, existed:, quest_id: nil)
        conn[:cap_records].insert(
          user_id: user_id, quest_id: quest_id, surface: surface,
          requested: requested, cap: cap, existed: existed, occurred_at: Time.now
        )
        nil
      end

      # The overhang rollup (I08 §4 "joins when §2.5 telemetry lands"):
      # `sum(existed - cap)` over rows where `existed > cap`, grouped by
      # surface — the rows the user never saw, per surface. Returns rows
      # {surface, overhang, capped_requests}.
      def overhang_by_surface(conn, user_id:)
        conn[:cap_records]
          .where(user_id: user_id)
          .where(Sequel[:cap_records][:existed] > Sequel[:cap_records][:cap])
          .group(:surface)
          .select(Sequel[:cap_records][:surface],
                  Sequel.lit("sum(existed - cap) AS overhang"),
                  Sequel.lit("count(*) AS capped_requests"))
          .order(:surface).to_a
      end
    end
  end
end
