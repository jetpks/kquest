# frozen_string_literal: true

# The I06 quest-process CONFIG TABLES — lane-authored NEW schema (I06 froze
# the two TSVs, not table DDL). Columns are the TSV headers verbatim
# (plus `id`, plus `ordinal` for transitions, preserving file order — the
# P-PRIO law); the enum CHECKs are the I06 checker's exact enums
# (check-transitions.sh FROM/EVENT/TO/EXIT_ENUM, check-coverage.sh's ruled
# action enum). plpgsql-free, I01 conventions: uuid PK gen_random_uuid(),
# text + CHECK IN enums, named ck_/uq_ constraints.
#
# The tables are DATA here — nothing evaluates them until ENTRY 4's phase
# runner (I06 §14: the runner evaluates the table, never encodes a
# transition). Seeded by config/db/seeds.rb from the app's byte-exact TSV
# copies (config/db/seeds/*.tsv).
Sequel.migration do
  up do
    run <<~'SQL'
      CREATE TABLE phase_transitions (
        id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        ordinal         integer NOT NULL CONSTRAINT ck_phase_transitions_ordinal
                        CHECK (ordinal >= 1),
        from_phase      text NOT NULL CONSTRAINT ck_phase_transitions_from_phase
                        CHECK (from_phase IN ('briefing-init', 'decompose', 'frontier-build',
                                              'descent', 'synthesis', 'verification',
                                              'any-phase', 'any-work-phase', 'any-finisher-phase')),
        event           text NOT NULL CONSTRAINT ck_phase_transitions_event
                        CHECK (event IN ('phase_complete', 'graph_invalid', 'transcript_ceiling',
                                         'slow_stall_unattended', 'retry_cap_exhausted',
                                         'budget_exhausted', 'phase_cap', 'verification_failed')),
        guard           text NOT NULL CONSTRAINT ck_phase_transitions_guard_nonempty
                        CHECK (char_length(btrim(guard)) > 0),
        to_phase        text NOT NULL CONSTRAINT ck_phase_transitions_to_phase
                        CHECK (to_phase IN ('decompose', 'frontier-build', 'descent', 'synthesis',
                                            'verification', 'quest-done', 'paused', 'stopped')),
        phase_kind_exit text NOT NULL CONSTRAINT ck_phase_transitions_phase_kind_exit
                        CHECK (phase_kind_exit IN ('autonomy-handoff', 'counter-exit',
                                                   'mass-floor-gate', 'mass-decay-armed',
                                                   'mass-decay-primary', 'plateau-cut-backstop',
                                                   'drained-exit', 'descent-repeat',
                                                   'citation-coverage-exit', 'verification-terminal',
                                                   'rework-pause', 'route-to-synthesis',
                                                   'pause-and-present', 'stop-loud')),
        evidence        text NOT NULL,
        CONSTRAINT uq_phase_transitions_ordinal UNIQUE (ordinal)
      );

      CREATE TABLE stop_rules (
        id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        rule_id    text NOT NULL CONSTRAINT ck_stop_rules_rule_id
                   CHECK (rule_id ~ '^SR-[0-9]{2}$'),
        scope      text NOT NULL CONSTRAINT ck_stop_rules_scope
                   CHECK (scope IN ('quest', 'phase')),
        metric     text NOT NULL CONSTRAINT ck_stop_rules_metric_nonempty
                   CHECK (char_length(btrim(metric)) > 0),
        "default"  numeric NOT NULL,
        operator   text NOT NULL CONSTRAINT ck_stop_rules_operator
                   CHECK (operator IN ('>=', '>', '<=', '<')),
        action     text NOT NULL CONSTRAINT ck_stop_rules_action
                   CHECK (action IN ('route-to-synthesis', 'pause-and-present', 'stop-loud', 'adjust')),
        provenance text NOT NULL,
        config_key text NOT NULL CONSTRAINT ck_stop_rules_config_key_nonempty
                   CHECK (char_length(btrim(config_key)) > 0),
        CONSTRAINT uq_stop_rules_rule_id UNIQUE (rule_id),
        CONSTRAINT uq_stop_rules_config_key UNIQUE (config_key)
      );
    SQL
  end

  down do
    run <<~'SQL'
      DROP TABLE stop_rules;
      DROP TABLE phase_transitions;
    SQL
  end
end
