# frozen_string_literal: true

require_relative "test_helper"

class SchemaTest < Minitest::Test
  DOMAIN_TABLES = %i[users conversations messages].freeze

  def conn
    @conn ||= Space::Server::App["db.gateway"].connection
  end

  def col(table, name)
    conn.schema(table).to_h.fetch(name)
  end

  def test_all_five_tables_exist
    existing = conn.tables
    DOMAIN_TABLES.each { |t| assert_includes existing, t, "table #{t} missing" }
  end

  def test_no_active_storage_tables
    existing = conn.tables
    refute_includes existing, :active_storage_attachments
    refute_includes existing, :active_storage_blobs
  end

  def test_users_key_columns
    assert_equal "timestamp with time zone", col(:users, :created_at)[:db_type]
    assert_equal "jsonb",                   col(:users, :github_orgs)[:db_type]
    assert_equal false,                     col(:users, :github_uid)[:allow_null]
    assert_equal false,                     col(:users, :username)[:allow_null]
    assert_equal true,                      col(:users, :orgs_synced_at)[:allow_null]
  end

  def test_conversations_status_integer
    c = col(:conversations, :status)
    assert_equal "integer", c[:db_type]
    assert_equal false,     c[:allow_null]
    assert_match "0",       c[:default].to_s
  end

  def test_conversations_published_boolean_default_false
    c = col(:conversations, :published)
    assert_equal "boolean", c[:db_type]
    assert_match "false",   c[:default].to_s
  end

  # ── I08 schema fold: runs dropped, ingest-mouth metadata added ──────────────

  def test_runs_table_is_gone
    refute_includes conn.tables, :runs, "the runs table must be dropped (schema fold)"
  end

  def test_conversations_ingest_mouth_columns
    assert_equal "bigint", col(:conversations, :space_id)[:db_type]
    assert_equal true,     col(:conversations, :space_id)[:allow_null]
    assert_equal "text",   col(:conversations, :agent_role)[:db_type]
    assert_equal "text",   col(:conversations, :agent_name)[:db_type]
    assert_equal "text",   col(:conversations, :model)[:db_type]

    applied = col(:conversations, :applied_record_ids)
    assert_equal "jsonb", applied[:db_type]
    assert_equal false,   applied[:allow_null]
    assert_match "[]",    applied[:default].to_s
  end

  def test_conversations_space_id_indexed
    idx = conn.indexes(:conversations)
    assert idx.key?(:index_conversations_on_space_id), "space_id must be indexed"
  end

  def test_messages_content_jsonb_not_null
    c = col(:messages, :content)
    assert_equal "jsonb", c[:db_type]
    assert_equal false,   c[:allow_null]
    assert_match "[]",    c[:default].to_s
  end

  def test_messages_occurred_at_timestamptz_nullable
    c = col(:messages, :occurred_at)
    assert_equal "timestamp with time zone", c[:db_type]
    assert_equal true, c[:allow_null]
  end

  def test_all_tables_queryable
    DOMAIN_TABLES.each do |t|
      count = conn[t].count
      assert count >= 0, "#{t} not queryable"
    end
  end
end
