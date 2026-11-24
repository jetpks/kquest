# frozen_string_literal: true

# `ladder_passes` — the I08 §10 durable carrier, landed VERBATIM (DR-06:
# "the arc's schema entry lands it verbatim or amends it by decision
# record" — no amendment is needed; single-quoted heredoc per THE HEREDOC
# LAW, see 20261124000002_create_core_model_i01.rb).
#
# Day one the rung rule is REVIEWABLE, not machine-checked: the routing-map
# editor (ENTRY 5) cites ladder_passes ids per model per phase kind; the
# rung harness that seeds this table is ENTRY 4's (I08 §12).
Sequel.migration do
  up do
    run <<~'SQL'
      CREATE TABLE ladder_passes (
        id            uuid PRIMARY KEY,
        model         text        NOT NULL,          -- provider wire_name (data, never query text)
        rung          text        NOT NULL CHECK (rung IN ('probe','smoke','partial','full')),
        serving_stack text        NOT NULL,          -- a rung is (model, stack, date), never a title (I07 §7)
        passed_at     timestamptz NOT NULL,
        evidence_ref  text        NOT NULL,          -- the rung's transcript dir / ledger ids
        passed_by     text        NOT NULL           -- the operator who accepted the rung
      );
      CREATE UNIQUE INDEX uq_ladder_passes_rung ON ladder_passes (model, rung, serving_stack, passed_at);
    SQL
  end

  down do
    run <<~'SQL'
      DROP TABLE ladder_passes;
    SQL
  end
end
