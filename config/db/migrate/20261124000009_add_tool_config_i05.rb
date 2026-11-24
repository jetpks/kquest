# frozen_string_literal: true

# The I05 tool-surface CONFIG TABLES — lane-authored NEW schema (the I06/I13
# config-table precedent: lane-authored additive config schema, columns
# verbatim from the design's naming, enum CHECKs, config data never encoding
# logic). plpgsql-free, I01 conventions: uuid PK gen_random_uuid(), named
# ck_/uq_ constraints, CHECK enums. The fidelity catalog enumerates law
# tables by name — these tables sit OUTSIDE it (the I06/I13 verified
# mechanism).
#
#   tool_config   — the tool surface's config home (I14's Grounds ruling;
#                   `engine_config` is numeric-only with budget-line
#                   semantics). The tools need numeric (k, floor, caps) AND
#                   text (the claim-model registry ref) values: exactly one
#                   value carrier per row (ck_tool_config_exactly_one).
#   web_providers — the web wire's provider rows (the ProviderDesk/registry
#                   posture): the web tools resolve their wire endpoint by
#                   config row the way ProviderDesk resolves chat providers
#                   and the registry resolves embed models. NO row is seeded
#                   (the I13 llm_providers precedent): tests upsert their own
#                   rows against their own in-process mock. `api_key_ref` is
#                   a credential REFERENCE (`env:<NAME>`), resolved through
#                   the landed Kquest::Pipeline::KeyRef — never key material.
Sequel.migration do
  up do
    run <<~'SQL'
      CREATE TABLE tool_config (
        key        text PRIMARY KEY CONSTRAINT ck_tool_config_key_nonempty
                   CHECK (char_length(btrim(key)) > 0),
        num_value  numeric CONSTRAINT ck_tool_config_num_nonneg
                   CHECK (num_value IS NULL OR num_value >= 0),
        text_value text,
        provenance text NOT NULL CONSTRAINT ck_tool_config_provenance_nonempty
                   CHECK (char_length(btrim(provenance)) > 0),
        created_at timestamp with time zone NOT NULL DEFAULT now(),
        CONSTRAINT ck_tool_config_exactly_one
                   CHECK ((num_value IS NULL) <> (text_value IS NULL))
      );

      CREATE TABLE web_providers (
        id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name        text NOT NULL CONSTRAINT ck_web_providers_name_nonempty
                    CHECK (char_length(btrim(name)) > 0),
        base_url    text NOT NULL CONSTRAINT ck_web_providers_base_url_nonempty
                    CHECK (char_length(btrim(base_url)) > 0),
        api_key_ref text CONSTRAINT ck_web_providers_api_key_ref
                    CHECK (api_key_ref IS NULL OR
                           api_key_ref ~ '^env:[A-Za-z_][A-Za-z0-9_]*$'),
        params      jsonb,
        created_at  timestamp with time zone NOT NULL DEFAULT now(),
        CONSTRAINT ck_web_providers_base_url_http CHECK (base_url ~ '^https?://'),
        CONSTRAINT uq_web_providers_name UNIQUE (name)
      );
    SQL
  end

  down do
    run <<~'SQL'
      DROP TABLE web_providers;
      DROP TABLE tool_config;
    SQL
  end
end
