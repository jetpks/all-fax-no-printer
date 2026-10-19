# frozen_string_literal: true

# I15 structured-iterations-ingest. The modeled store behind the observation
# deck's structured record: frozen gates, lane dispositions, and verdict
# rulings as first-class rows (markdown on disk stays the source of truth;
# these tables back the bearer-authed ingest mouths POST /iterations/ingest/*).
# Additive only. Old migrations are history; recovery is the
# pre-observation-deck tag on origin.
Sequel.migration do
  up do
    alter_table(:iterations) do
      add_column :branch, String
    end

    create_table(:gates) do
      primary_key :id, type: :Bignum
      foreign_key :iteration_id, :iterations, null: false, type: :bigint, on_delete: :cascade
      column :gate_id,    String,   null: false
      column :ac,         String
      column :cwd,        String
      column :cmd,        String,   null: false
      column :timeout,    :numeric
      column :expect,     :jsonb
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
      index [:iteration_id, :gate_id], unique: true, name: :index_gates_on_iteration_id_and_gate_id
    end

    create_table(:lanes) do
      primary_key :id, type: :Bignum
      foreign_key :iteration_id, :iterations, null: false, type: :bigint, on_delete: :cascade
      column :name,       String, null: false
      column :repo,       String
      column :base_sha,   String
      column :model,      String
      column :harness,    String
      column :effort,     String
      column :touch_set,  :jsonb, null: false, default: Sequel.lit("'[]'::jsonb")
      column :status,     String
      column :escalations, :jsonb, null: false, default: Sequel.lit("'[]'::jsonb")
      column :bounds_override_reason, String
      column :merge_sha,  String
      column :integration_branch, String
      column :integrated_at, :timestamptz
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
      index [:iteration_id, :name], unique: true, name: :index_lanes_on_iteration_id_and_name
    end

    create_table(:gate_results) do
      primary_key :id, type: :Bignum
      foreign_key :iteration_gate_id, :gates, null: false, type: :bigint, on_delete: :cascade
      foreign_key :lane_id, :lanes, null: false, type: :bigint, on_delete: :cascade
      column :status,     String, null: false
      column :reason,     String
      column :transcript, String
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
      index [:iteration_gate_id, :lane_id], unique: true, name: :index_gate_results_on_iteration_gate_id_and_lane_id
    end

    create_table(:verdicts) do
      primary_key :id, type: :Bignum
      foreign_key :iteration_id, :iterations, null: false, type: :bigint, on_delete: :cascade
      column :decision,           String, null: false
      column :phase0_resolutions, :jsonb, null: false, default: Sequel.lit("'[]'::jsonb")
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
      index [:iteration_id], unique: true, name: :index_verdicts_on_iteration_id
    end

    create_table(:verdict_rulings) do
      primary_key :id, type: :Bignum
      foreign_key :verdict_id, :verdicts, null: false, type: :bigint, on_delete: :cascade
      column :ac,     String, null: false
      column :ruling, String, null: false
      column :note,   String
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
      index [:verdict_id, :ac], unique: true, name: :index_verdict_rulings_on_verdict_id_and_ac
    end
  end

  down do
    raise Sequel::Error, "I15 iteration-record tables are one-way; recover from the pre-observation-deck tag"
  end
end
