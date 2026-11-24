# frozen_string_literal: true

# The I04 agent-loop CONFIG TABLES — lane-authored NEW schema (the I06
# config-table precedent: lane-authored additive config schema, columns
# verbatim from the design's naming, enum CHECKs, config data never encoding
# logic). plpgsql-free, I01 conventions: uuid PK gen_random_uuid(), named
# ck_/uq_ constraints, CHECK enums. The fidelity catalog enumerates law
# tables by name — these tables sit OUTSIDE it (verified: the I06 precedent).
#
#   llm_providers      — I04 DESIGN §3's provider config row. NO row is seeded:
#                        provider rows are operator/session-minted config (the
#                        pipeline test-model precedent); tests and the headless
#                        script upsert their own rows against their own
#                        endpoints. `api_key_ref` is a credential REFERENCE,
#                        never a secret (NULL = no Authorization header).
#   engine_config      — the loop-wide caps/budget lines (I04 §2.5/§7, DR-09):
#                        {key, value, mode ∈ advisory|hard, provenance}. `mode`
#                        is read ONLY by budget-guard consumers (DR-09's
#                        advisory-by-default ruling); retry caps do not consult
#                        it.
#   subagent_profiles  — I05 §8 / I04 DR-08: profiles are CONFIG DATA — a named
#                        restriction of the registered surface; the registration
#                        IS the restriction. No recursion is a SubagentRunner
#                        law (E-RESTRICT), not a schema one.
Sequel.migration do
  up do
    run <<~'SQL'
      CREATE TABLE llm_providers (
        id                             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name                           text NOT NULL CONSTRAINT ck_llm_providers_name_nonempty
                                       CHECK (char_length(btrim(name)) > 0),
        base_url                       text NOT NULL CONSTRAINT ck_llm_providers_base_url_nonempty
                                       CHECK (char_length(btrim(base_url)) > 0),
        api_key_ref                    text CONSTRAINT ck_llm_providers_api_key_ref
                                       CHECK (api_key_ref IS NULL OR
                                              api_key_ref ~ '^env:[A-Za-z_][A-Za-z0-9_]*$'),
        dialect                        text,
        model_id                       text NOT NULL CONSTRAINT ck_llm_providers_model_id_nonempty
                                       CHECK (char_length(btrim(model_id)) > 0),
        context_window                 integer NOT NULL CONSTRAINT ck_llm_providers_context_window
                                       CHECK (context_window > 0),
        max_tokens                     integer,
        reasoning                      boolean NOT NULL,
        thinking_level_map             jsonb,
        timeout_s                      integer,
        ttfb_timeout_s                 integer,
        inactivity_timeout_s           integer,
        max_retries                    integer,
        transcript_ceiling_warn_bytes  integer NOT NULL DEFAULT 450000,
        transcript_ceiling_hard_bytes  integer NOT NULL DEFAULT 496000,
        cache_wall_tokens              integer,
        cost_per_mtok_in               numeric(12,6),
        cost_per_mtok_out              numeric(12,6),
        created_at                     timestamp with time zone NOT NULL DEFAULT now(),
        CONSTRAINT uq_llm_providers_name UNIQUE (name),
        CONSTRAINT ck_llm_providers_retries_nonneg CHECK ((max_retries IS NULL) OR (max_retries >= 0)),
        CONSTRAINT ck_llm_providers_timeouts_positive CHECK ((
          (timeout_s IS NULL OR timeout_s > 0) AND
          (ttfb_timeout_s IS NULL OR ttfb_timeout_s > 0) AND
          (inactivity_timeout_s IS NULL OR inactivity_timeout_s > 0)
        )),
        CONSTRAINT ck_llm_providers_ceilings_positive CHECK ((
          (transcript_ceiling_warn_bytes > 0) AND (transcript_ceiling_hard_bytes > 0) AND
          (cache_wall_tokens IS NULL OR cache_wall_tokens > 0)
        )),
        CONSTRAINT ck_llm_providers_costs_nonneg CHECK ((
          (cost_per_mtok_in IS NULL OR cost_per_mtok_in >= 0) AND
          (cost_per_mtok_out IS NULL OR cost_per_mtok_out >= 0)
        ))
      );

      CREATE TABLE engine_config (
        key        text PRIMARY KEY,
        value      numeric NOT NULL CONSTRAINT ck_engine_config_value CHECK (value >= 0),
        mode       text NOT NULL DEFAULT 'advisory' CONSTRAINT ck_engine_config_mode
                   CHECK (mode IN ('advisory', 'hard')),
        provenance text NOT NULL
      );

      CREATE TABLE subagent_profiles (
        name       text PRIMARY KEY CONSTRAINT ck_subagent_profiles_name_nonempty
                   CHECK (char_length(btrim(name)) > 0),
        tools      jsonb NOT NULL CONSTRAINT ck_subagent_profiles_tools
                   CHECK (jsonb_typeof(tools) = 'array' AND jsonb_array_length(tools) > 0),
        provenance text NOT NULL
      );
    SQL
  end

  down do
    run <<~'SQL'
      DROP TABLE subagent_profiles;
      DROP TABLE engine_config;
      DROP TABLE llm_providers;
    SQL
  end
end
