# frozen_string_literal: true

require "digest"
require "securerandom"
require "stringio"

module Kquest
  module Pipeline
    # The fixture-injected fetch body (the network leg is ENTRY 3's
    # web_fetch tool — I08 §7's single ingestion door; this body never
    # touches Exa or any key). Registers a content-addressed source:
    #
    #   canonical_url  = CanonicalUrl.call(url)
    #   urn            = "kb:src:" + base58(sha256(canonical_url || snapshot_sha))[0,10]
    #   idem key       = "fetch:<user_id>:<urn>"   (USER-scoped — one source
    #                   serves many quests; D3 fetch-once is per user)
    #
    # The two blobs ride Kquest::BlobUploader's locations (snapshot at
    # `snapshots/<user>/<urn>`, raw at `raw/<user>/<fetch_id>`); the job row
    # is minted COMPLETE inside the source-registration transaction
    # (bookkeeping for work that just happened — a failed fetch leaves no
    # row; the caller retries the whole body). No usage row: web-call budget
    # is the web ops' ledger, not token spend.
    module FetchBody
      module_function

      def call(user_id:, url:, title:, role:, snapshot_text:, raw_body:,
               quest_id: nil, phase_id: nil, published_at: nil,
               conn: Kquest::App["db.gateway"].connection)
        raise Error, "unknown source role: #{role.inspect}" unless %w[citable agenda].include?(role)

        canonical = CanonicalUrl.call(url)
        snapshot_sha = Digest::SHA256.hexdigest(snapshot_text)
        raw_sha = Digest::SHA256.hexdigest(raw_body)
        urn = "kb:src:" + Base58.encode(Digest::SHA256.digest(canonical + snapshot_sha))[0, 10]
        idem_key = "fetch:#{user_id}:#{urn}"

        conn.transaction do
          existing = conn[:sources].where(user_id: user_id, urn: urn).first
          if existing
            # Content-address dedup: same user + same bytes → same source.
            # The requesting quest's membership still registers (one source
            # serves many quests); the blobs are already durable (same urn
            # ⇒ same snapshot bytes).
            register_membership!(conn, quest_id, existing[:id], user_id)
            mint_complete_row!(conn, SecureRandom.uuid, user_id, quest_id, phase_id,
              idem_key, existing[:id]) unless conn[:embed_jobs].where(idem_key: idem_key).first
            return {source_id: existing[:id], urn: urn, created: false}
          end

          fetch_id = SecureRandom.uuid
          Kquest::BlobUploader.store(StringIO.new(snapshot_text), kind: :snapshot, user: user_id, source_urn: urn)
          Kquest::BlobUploader.store(StringIO.new(raw_body), kind: :raw, user: user_id, fetch_id: fetch_id)

          source_id = conn[:sources].insert(
            user_id: user_id,
            url: url,
            canonical_url: canonical,
            urn: urn,
            title: title,
            role: role,
            published_at: published_at,
            fetched_at: Time.now,
            snapshot_sha256: snapshot_sha,
            raw_sha256: raw_sha,
            snapshot_char_count: snapshot_text.length
          )
          register_membership!(conn, quest_id, source_id, user_id)
          mint_complete_row!(conn, fetch_id, user_id, quest_id, phase_id, idem_key, source_id)
          {source_id: source_id, urn: urn, created: true}
        end
      end

      def register_membership!(conn, quest_id, source_id, user_id)
        return unless quest_id

        # insert_ignore (ON CONFLICT DO NOTHING): pk (quest_id, source_id) —
        # a repeat registration is a no-op, never an error. (Sequel's
        # insert_ignore is a dataset modifier: insert_ignore.insert(...).)
        conn[:quest_sources].insert_ignore.insert(
          quest_id: quest_id, source_id: source_id, user_id: user_id
        )
        nil
      end

      def mint_complete_row!(conn, job_id, user_id, quest_id, phase_id, idem_key, source_id)
        now = Time.now
        conn[:embed_jobs].insert(
          id: job_id,
          user_id: user_id,
          quest_id: quest_id,
          phase_id: phase_id,
          kind: "fetch",
          state: "complete",
          idem_key: idem_key,
          source_id: source_id,
          total_items: 1,
          done_items: 1,
          started_at: now,
          ended_at: now
        )
        nil
      end
    end
  end
end
