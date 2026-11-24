# frozen_string_literal: true

require_relative "test_helper"

class SchemaTest < Minitest::Test
  def conn
    @conn ||= Kquest::App["db.gateway"].connection
  end

  def col(table, name)
    conn.schema(table).to_h.fetch(name)
  end

  def test_users_table_exists
    assert_includes conn.tables, :users, "table users missing"
  end

  def test_users_key_columns
    assert_equal "uuid", col(:users, :id)[:db_type]
    assert_equal false,                  col(:users, :handle)[:allow_null]
    assert_equal false,                  col(:users, :github_uid)[:allow_null]
    assert_equal false,                  col(:users, :username)[:allow_null]
    assert_equal "timestamp with time zone", col(:users, :created_at)[:db_type]
    assert_equal "timestamp with time zone", col(:users, :updated_at)[:db_type]
  end

  # Exact column set: the unified tenant root (I11 Part 2) — the I01 law
  # shape (uuid id, handle, display_name) plus the six additive auth columns.
  def test_users_column_set_is_the_unified_tenant_root
    columns = conn.schema(:users).map { |col| col.first.to_s }
    assert_equal %w[avatar_url created_at display_name email github_uid handle id
                    name updated_at username],
                 columns.sort
  end

  def test_users_github_uid_unique_indexed
    idx = conn.indexes(:users)
    assert idx.key?(:index_users_on_github_uid), "github_uid must be unique-indexed"
  end

  def test_no_active_storage_tables
    existing = conn.tables
    refute_includes existing, :active_storage_attachments
    refute_includes existing, :active_storage_blobs
  end

  def test_users_table_queryable
    count = conn[:users].count
    assert count >= 0, "users not queryable"
  end
end
