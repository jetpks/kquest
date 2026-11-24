# frozen_string_literal: true

# Users-table unification (I11 Specification Part 2): drop the mint's
# bigint-identity OAuth users table so migration 2 can recreate `users` as
# the I01 tenant root (uuid PK, handle). Nothing FKs the substrate table at
# this point (`documents` carries no user FK, verified at spec time).
#
# The auth columns come back additively in
# 20261124000006_add_users_auth_columns.rb — ONE table, the I01 shape, is
# the ruled unification.
Sequel.migration do
  up do
    run <<~'SQL'
      DROP TABLE users;
    SQL
  end

  down do
    # Honest reversal: recreate the substrate users table exactly as
    # 20261030000000_create_users.rb built it (bigint identity PK, the eight
    # substrate columns, the github_uid unique index).
    create_table(:users) do
      primary_key :id, type: :Bignum
      column :avatar_url, String
      column :created_at, :timestamptz, null: false
      column :email, String
      column :github_uid, String, null: false
      column :name, String
      column :updated_at, :timestamptz, null: false
      column :username, String, null: false
      index :github_uid, unique: true, name: :index_users_on_github_uid
    end
  end
end
