-- ============================================================================
-- I11 migration fidelity — the ONE canonical catalog query (AC1/AC5 of the
-- design-law harness). Run IDENTICALLY against both sides:
--   side A = scratch db built by applying the design DDL verbatim via psql
--            (I01 schema.sql + I02 schema-i02.sql + I03 schema-i03.sql)
--   side B = scratch db built by the app's OWN migrations
-- (script/design_fidelity_check.sh drives both sides and sha256-compares).
--
-- Serializes the FROZEN design table/view set — 27 tables + 9 views — as
-- deterministic text lines (ORDER BY the emitted line):
--   every named constraint (name + pg_get_constraintdef),
--   every column (name, type, NOT NULL, generated expression),
--   every index (name + def),
--   every view (name + pg_get_viewdef).
--
-- The ONLY exemptions (frozen; the unified users table, I11 Part 2):
--   - the six additive auth columns (github_uid, username, name, email,
--     avatar_url, updated_at) on users — INCLUDING the two named NOT NULL
--     constraints that carry their NOT NULL law (PG 18 turns ALTER TABLE
--     SET NOT NULL into named pg_constraint rows; the design side has no
--     such rows since its users never carries the auth columns)
--   - the index_users_on_github_uid index
-- No asymmetric validators: the same query runs against both dbs; the
-- exemptions apply to both sides equally.
--
-- plpgsql-free (plain SQL, no DO blocks / functions).
-- ============================================================================

WITH law_tables(name) AS (
  SELECT * FROM (VALUES
    -- I01 core model (17)
    ('users'), ('sources'), ('quests'), ('quest_sources'), ('chunk_strategies'),
    ('chunks'), ('phases'), ('sessions'), ('claims'), ('evidence'),
    ('evidence_edges'), ('claim_derivations'), ('frontier_entries'),
    ('conflicts'), ('conflict_sources'), ('tool_calls'), ('usage_events'),
    -- I02 cross-quest (6)
    ('quest_lifecycle_events'), ('report_versions'), ('report_citations'),
    ('workspaces'), ('workspace_members'), ('resource_grants'),
    -- I03 retrieval (4)
    ('embedding_models'), ('embed_jobs'), ('emb_bge_m3_1024'), ('emb_minilm_ab_384')
  ) AS t(n)
),
law_views(name) AS (
  SELECT * FROM (VALUES
    -- I01 (5)
    ('v_unmined_sources'), ('v_decompose_remaining'), ('v_frontier_open'),
    ('v_frontier_mass'), ('v_claim_closure'),
    -- I02 (4)
    ('v_canonical_claims'), ('v_quest_graph_fingerprint'),
    ('v_quest_lineage'), ('v_resource_visibility')
  ) AS v(n)
),
exempt_columns(colname) AS (
  SELECT * FROM (VALUES
    ('github_uid'), ('username'), ('name'), ('email'), ('avatar_url'), ('updated_at')
  ) AS e(n)
)
SELECT line FROM (
  -- named constraints over the law tables (name + definition)
  SELECT 'constraint|' || t.relname || '|' || c.conname || '|' || pg_get_constraintdef(c.oid) AS line
  FROM pg_constraint c
  JOIN pg_class t    ON t.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public' AND t.relname IN (SELECT name FROM law_tables)
    -- the users-unification exemption: the named NOT NULL constraints that
    -- carry github_uid/username NOT NULL (the six auth columns' law)
    AND NOT (t.relname = 'users' AND c.contype = 'n'
             AND c.conname IN ('users_github_uid_not_null', 'users_username_not_null'))
  UNION ALL
  -- columns over the law tables (name, type, NOT NULL, generated expression),
  -- minus the frozen users auth-column exemption
  SELECT 'column|' || t.relname || '|' || a.attname || '|'
         || format_type(a.atttypid, a.atttypmod)
         || '|notnull=' || (a.attnotnull::int)::text
         || '|gen=' || COALESCE(NULLIF(pg_get_expr(d.adbin, d.adrelid), ''), '-') AS line
  FROM pg_attribute a
  JOIN pg_class t    ON t.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
  WHERE n.nspname = 'public' AND t.relname IN (SELECT name FROM law_tables)
    AND a.attnum > 0 AND NOT a.attisdropped
    AND a.attname <> 'ctid'
    AND NOT (t.relname = 'users' AND a.attname IN (SELECT colname FROM exempt_columns))
  UNION ALL
  -- indexes over the law tables (name + def), minus the frozen
  -- index_users_on_github_uid exemption
  SELECT 'index|' || i.tablename || '|' || i.indexname || '|' || i.indexdef AS line
  FROM pg_indexes i
  WHERE i.schemaname = 'public' AND i.tablename IN (SELECT name FROM law_tables)
    AND i.indexname <> 'index_users_on_github_uid'
  UNION ALL
  -- the law views (name + definition)
  SELECT 'view|' || v.viewname || '|' || pg_get_viewdef(c.oid) AS line
  FROM pg_views v
  JOIN pg_class c    ON c.relname = v.viewname
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE v.schemaname = 'public' AND v.viewname IN (SELECT name FROM law_views)
) AS law
ORDER BY line;
