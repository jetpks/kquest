# frozen_string_literal: true

module Kquest
  module Pipeline
    # The embed_jobs row-lifecycle transitions, all over ONE Sequel
    # connection (the J-SPEND same-transaction law). The ledger never lies:
    # a failure keeps the partial cursor and explains itself; a completion's
    # spend row commits with the terminal state, never after it.
    module State
      NOTE_MAX = 2000

      module_function

      # pending→running, or a resume (started_at stamped only on the first
      # transition). total_items rides the transition — the progress CHECK
      # (done_items <= total_items) bites when the cursor advances past a
      # stale total, and a grown target set resumes cleanly.
      def mark_running!(conn, row, total_items)
        conn[:embed_jobs].where(id: row[:id]).update(
          state: "running",
          total_items: total_items,
          started_at: row[:started_at] || Time.now
        )
        nil
      end

      # Terminal, explained: the message lands verbatim (truncated to
      # NOTE_MAX) in error_note; the partial cursor is kept.
      def mark_failed!(conn, row, note)
        conn[:embed_jobs].where(id: row[:id]).update(
          state: "failed",
          error_note: note.to_s[0, NOTE_MAX],
          started_at: row[:started_at] || Time.now,
          ended_at: Time.now
        )
        nil
      end

      # fetch/chunk completion: no usage row (I03 law — fetch's web-call
      # budget is the web ops' ledger; chunking spends no tokens).
      def mark_complete!(conn, row, total_items)
        conn[:embed_jobs].where(id: row[:id]).update(
          state: "complete",
          total_items: total_items,
          done_items: total_items,
          ended_at: Time.now
        )
        nil
      end

      # The J-SPEND wiring direction: the usage_events insert and the job's
      # terminal update in ONE transaction — both CHECKs (every completed
      # embed job links an embedding usage row; every embedding usage row
      # links back from a completed embed job) hold by construction.
      def mark_complete_with_spend!(conn, row, total_items, usage_attrs)
        conn.transaction do
          usage_event_id = conn[:usage_events].insert(usage_attrs)
          conn[:embed_jobs].where(id: row[:id]).update(
            state: "complete",
            total_items: total_items,
            done_items: total_items,
            usage_event_id: usage_event_id,
            ended_at: Time.now
          )
          usage_event_id
        end
      end

      # Grounds decision 2: the usage row's session = the job's triggering
      # phase's LATEST session (started_at DESC, id DESC) — re-derived from
      # durable rows, never from transient payload.
      def latest_session_of_phase(conn, row)
        return nil unless row[:phase_id]

        conn[:sessions]
          .where(phase_id: row[:phase_id])
          .order(Sequel.desc(:started_at), Sequel.desc(:id))
          .first
      end
    end
  end
end
