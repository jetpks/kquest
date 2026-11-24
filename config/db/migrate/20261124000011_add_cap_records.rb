# frozen_string_literal: true

# The I16 cap-telemetry carrier (I08 §2.5 + L15): ONE `cap_records` row per
# capped listing request, written in the SAME transaction as the read. The
# rollup (existed > cap, summed as existed - cap per surface) feeds the
# dashboard's blind-spot panel (I07 §6/DR-05: the overhang "lands with the
# SSE dashboard") and the frontier inspector's overhang badge. Lane-authored
# NEW schema OUTSIDE the fidelity catalog (the tw_*/I06/I13 additive
# precedent) — the digest stays 1115 law objects, byte-identical.
#
# Both FKs carry ON DELETE CASCADE (matrix-proven): a plain FK wedges every
# landed fixture teardown that deletes users/quests (OrchestratorFixtures
# does not know this table); the cascade keeps those cleanups working with
# ZERO test/support edits — telemetry rows follow their tenancy.
Sequel.migration do
  up do
    run <<~'SQL'
      CREATE TABLE cap_records (
        id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        user_id     uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
        quest_id    uuid          REFERENCES quests (id) ON DELETE CASCADE,
        surface     text NOT NULL CONSTRAINT ck_cap_records_surface_nonempty
                    CHECK (char_length(btrim(surface)) > 0),
        requested   integer NOT NULL CONSTRAINT ck_cap_records_requested_nonneg
                    CHECK (requested >= 0),
        cap         integer NOT NULL CONSTRAINT ck_cap_records_cap_positive
                    CHECK (cap > 0),
        existed     integer NOT NULL CONSTRAINT ck_cap_records_existed_nonneg
                    CHECK (existed >= 0),
        occurred_at timestamp with time zone NOT NULL DEFAULT now()
      );

      CREATE INDEX idx_cap_records_user_surface
        ON cap_records (user_id, surface, occurred_at);
    SQL
  end

  down do
    run <<~'SQL'
      DROP TABLE IF EXISTS cap_records;
    SQL
  end
end
