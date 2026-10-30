# frozen_string_literal: true

# I11 narration-split (lane afnp). The loop's CURRENT phase per iteration —
# the scalar facet behind the fifth bearer mouth POST /iterations/ingest/phase.
# phase_kind is free text at the mouth (the status discipline — the emitting
# CLI pins the vocabulary); phase_at is stamped by the SERVER clock at ingest
# (the payload carries no timestamp); phase_note rides along when a ping
# carries one and upserts only when present. Additive only, one-way per the
# house pattern (see create_iteration_record_tables).
Sequel.migration do
  up do
    alter_table(:iterations) do
      add_column :phase_kind, String
      add_column :phase_at,   :timestamptz
      add_column :phase_note, String
    end
  end

  down do
    raise Sequel::Error, "phase columns are one-way; recover from the pre-narration-split tag"
  end
end
