# frozen_string_literal: true

# I08 conversations-unification. The captured-session concept is now the
# conversation itself: the runs table (the I02–I06 intermediate "run" row)
# dies whole, and conversations gain the metadata the ingest mouth
# (POST /conversations/ingest) materializes — space linkage (implicit from
# the session's working directory or the X-Space-Slug header), agent
# role/name/model, and the per-record idempotency log. Old migrations are
# history; recovery is the pre-observation-deck tag on origin.
Sequel.migration do
  up do
    drop_table :runs
    alter_table(:conversations) do
      add_column :space_id, "bigint"
      add_column :agent_role, "text"
      add_column :agent_name, "text"
      add_column :model, "text"
      add_column :applied_record_ids, "jsonb", null: false, default: "[]"
      add_index :space_id, name: :index_conversations_on_space_id
    end
  end

  down do
    raise Sequel::Error, "I08 conversations-unification is one-way; recover from the pre-observation-deck tag"
  end
end
