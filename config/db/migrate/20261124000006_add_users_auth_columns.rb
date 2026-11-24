# frozen_string_literal: true

# Users-table unification (I11 Specification Part 2), second half: the six
# substrate auth columns ride the I01 tenant root ADDITIVELY. github_uid and
# username keep their substrate NOT NULL law; the github_uid unique index
# keeps the substrate's index name. The fidelity catalog's frozen exemption
# set is exactly these six columns + this index.
#
# The inert DEFAULT '' on github_uid/username: PG 18 checks NOT NULL before
# CHECK constraints (ExecConstraints order), so without a default the
# users-tenant-law probe (`INSERT INTO users (handle) VALUES ('BAD HANDLE!')`)
# is intercepted by the not-null violation and the handle-law CHECK could
# never fire. The default keeps NOT NULL (AC9) while letting the handle law
# be the FIRST refusal an illegitimate row meets. The substrate's own flows
# always supply both columns; the unique index permits at most one ''
# github_uid row.
Sequel.migration do
  up do
    run <<~'SQL'
      ALTER TABLE users
        ADD COLUMN github_uid text NOT NULL DEFAULT '',
        ADD COLUMN username   text NOT NULL DEFAULT '',
        ADD COLUMN name       text,
        ADD COLUMN email      text,
        ADD COLUMN avatar_url text,
        ADD COLUMN updated_at timestamptz;
      CREATE UNIQUE INDEX index_users_on_github_uid ON users (github_uid);
    SQL
  end

  down do
    run <<~'SQL'
      DROP INDEX index_users_on_github_uid;
      ALTER TABLE users
        DROP COLUMN updated_at,
        DROP COLUMN avatar_url,
        DROP COLUMN email,
        DROP COLUMN name,
        DROP COLUMN username,
        DROP COLUMN github_uid;
    SQL
  end
end
