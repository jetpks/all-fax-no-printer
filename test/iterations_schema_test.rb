# frozen_string_literal: true

require_relative "test_helper"

# I15 iteration-record store: the five modeled tables exist after db prepare,
# carry their key columns, and pin their natural keys with unique indexes.
class IterationsSchemaTest < Minitest::Test
  RECORD_TABLES = %i[gates lanes gate_results verdicts verdict_rulings].freeze

  def conn
    @conn ||= Space::Server::App["db.gateway"].connection
  end

  def col(table, name)
    conn.schema(table).to_h.fetch(name)
  end

  def test_all_five_record_tables_exist
    existing = conn.tables
    RECORD_TABLES.each { |t| assert_includes existing, t, "table #{t} missing" }
  end

  def test_gates_key_columns
    assert_equal "bigint", col(:gates, :iteration_id)[:db_type]
    assert_equal false,    col(:gates, :iteration_id)[:allow_null]
    assert_equal "text",   col(:gates, :gate_id)[:db_type]
    assert_equal false,    col(:gates, :gate_id)[:allow_null]
    assert_equal "text",   col(:gates, :cmd)[:db_type]
    assert_equal false,    col(:gates, :cmd)[:allow_null]
    assert_equal "numeric", col(:gates, :timeout)[:db_type]
    assert_equal true,     col(:gates, :timeout)[:allow_null]
    assert_equal "jsonb",  col(:gates, :expect)[:db_type]
  end

  def test_lanes_key_columns
    assert_equal "text",  col(:lanes, :name)[:db_type]
    assert_equal false,   col(:lanes, :name)[:allow_null]
    assert_equal "jsonb", col(:lanes, :touch_set)[:db_type]
    assert_equal false,   col(:lanes, :touch_set)[:allow_null]
    assert_match "[]",    col(:lanes, :touch_set)[:default].to_s
    assert_equal "jsonb", col(:lanes, :escalations)[:db_type]
    assert_match "[]",    col(:lanes, :escalations)[:default].to_s
    assert_equal "timestamp with time zone", col(:lanes, :integrated_at)[:db_type]
    assert_equal true,    col(:lanes, :integrated_at)[:allow_null]
  end

  def test_gate_results_key_columns
    assert_equal "bigint", col(:gate_results, :iteration_gate_id)[:db_type]
    assert_equal false,    col(:gate_results, :iteration_gate_id)[:allow_null]
    assert_equal "bigint", col(:gate_results, :lane_id)[:db_type]
    assert_equal false,    col(:gate_results, :lane_id)[:allow_null]
    assert_equal "text",   col(:gate_results, :status)[:db_type]
    assert_equal false,    col(:gate_results, :status)[:allow_null]
  end

  def test_verdicts_key_columns
    assert_equal "text",  col(:verdicts, :decision)[:db_type]
    assert_equal false,   col(:verdicts, :decision)[:allow_null]
    assert_equal "jsonb", col(:verdicts, :phase0_resolutions)[:db_type]
    assert_equal false,   col(:verdicts, :phase0_resolutions)[:allow_null]
    assert_match "[]",    col(:verdicts, :phase0_resolutions)[:default].to_s
  end

  def test_verdict_rulings_key_columns
    assert_equal "text",  col(:verdict_rulings, :ac)[:db_type]
    assert_equal false,   col(:verdict_rulings, :ac)[:allow_null]
    assert_equal "text",  col(:verdict_rulings, :ruling)[:db_type]
    assert_equal false,   col(:verdict_rulings, :ruling)[:allow_null]
  end

  def test_iterations_gains_branch_column
    assert_equal "text", col(:iterations, :branch)[:db_type]
    assert_equal true,   col(:iterations, :branch)[:allow_null]
  end

  def test_natural_key_unique_indexes
    idx = conn.indexes(:gates)
    assert idx.key?(:index_gates_on_iteration_id_and_gate_id), "gates natural key must be unique-indexed"

    idx = conn.indexes(:lanes)
    assert idx.key?(:index_lanes_on_iteration_id_and_name), "lanes natural key must be unique-indexed"

    idx = conn.indexes(:gate_results)
    assert idx.key?(:index_gate_results_on_iteration_gate_id_and_lane_id), "gate_results natural key must be unique-indexed"

    idx = conn.indexes(:verdicts)
    assert idx.key?(:index_verdicts_on_iteration_id), "verdicts must be unique per iteration"

    idx = conn.indexes(:verdict_rulings)
    assert idx.key?(:index_verdict_rulings_on_verdict_id_and_ac), "verdict_rulings natural key must be unique-indexed"
  end

  def test_all_record_tables_queryable
    RECORD_TABLES.each do |t|
      count = conn[t].count
      assert count >= 0, "#{t} not queryable"
    end
  end
end
