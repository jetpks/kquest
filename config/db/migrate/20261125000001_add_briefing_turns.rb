# frozen_string_literal: true

# The I18 briefing chat queue (the §8 amendment; Spec Part 1.1): ONE durable
# row per enqueued operator turn — the web action writes it through
# `OperatorWrite.enqueue_turn!` (the UI lane's door), the worker consumes it
# (BriefingExecutor, `state → consumed` at consume time). NO web-process LLM
# turn: the row IS the operator turn's durable record pre-consumption (L7 —
# PG is the truth, the stream is a tail; I08).
#
# Lane-authored NEW schema OUTSIDE the fidelity catalog (the cap_records
# precedent — the digest stays 1115 law objects, byte-identical). House shape
# per `20261124000011_add_cap_records.rb`: raw-SQL up block, ck_-named CHECKs,
# and ON DELETE CASCADE on every FK — a plain FK wedges every landed fixture
# teardown that deletes users/quests/sessions (OrchestratorFixtures does not
# know this table); the cascade keeps those cleanups working with ZERO
# test/support edits. `state` carries the dead-letter law: sign-off marks
# still-enqueued rows `skipped` (never silently dropped), consumption marks
# them `consumed` (the turn's receipt, not a retry flag).
Sequel.migration do
  up do
    run <<~'SQL'
      CREATE TABLE briefing_turns (
        id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        user_id     uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
        quest_id    uuid NOT NULL REFERENCES quests (id) ON DELETE CASCADE,
        session_id  uuid NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
        seq         integer NOT NULL,
        body        text NOT NULL,
        state       text NOT NULL DEFAULT 'enqueued',
        created_at  timestamp with time zone NOT NULL DEFAULT now(),
        consumed_at timestamp with time zone,
        CONSTRAINT ck_briefing_turns_seq_positive CHECK ((seq >= 1)),
        CONSTRAINT ck_briefing_turns_body_nonempty
          CHECK ((char_length(btrim(body)) > 0)),
        CONSTRAINT ck_briefing_turns_state
          CHECK ((state = ANY (ARRAY['enqueued'::text, 'consumed'::text, 'skipped'::text]))),
        CONSTRAINT uq_briefing_turns_session_seq UNIQUE (session_id, seq)
      );

      CREATE INDEX idx_briefing_turns_session_state
        ON briefing_turns (session_id, state, seq);
    SQL
  end

  down do
    run <<~'SQL'
      DROP TABLE IF EXISTS briefing_turns;
    SQL
  end
end
