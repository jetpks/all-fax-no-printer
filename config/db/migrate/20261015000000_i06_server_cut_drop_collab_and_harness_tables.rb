# frozen_string_literal: true

# D6: I06 server-cut. Drops the collaboration tier (annotations,
# conversation_shares), the remote-harness tier (jobs, profiles, providers),
# and the conversations.source_file_data column (the multipart-upload path's
# shrine blob). Old migrations are history; recovery is the
# `pre-observation-deck` tag on origin.
Sequel.migration do
  up do
    drop_table(:annotations)
    drop_table(:conversation_shares)
    drop_table(:jobs)
    drop_table(:profiles)
    drop_table(:providers)
    alter_table(:conversations) do
      drop_column :source_file_data
    end
  end

  down do
    raise Sequel::Error, "I06 server-cut is one-way; recover from the pre-observation-deck tag"
  end
end