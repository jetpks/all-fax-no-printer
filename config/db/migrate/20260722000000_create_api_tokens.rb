# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:api_tokens) do
      primary_key :id, type: :Bignum
      foreign_key :user_id, :users, null: false, type: :bigint, on_delete: :cascade
      column :name, String, null: false
      column :token_hash, String, null: false
      column :created_at, :timestamptz, null: false
      column :last_used_at, :timestamptz
      column :revoked_at, :timestamptz
      index :user_id, name: :index_api_tokens_on_user_id
      index :token_hash, unique: true, name: :index_api_tokens_on_token_hash
    end
  end

  down do
    drop_table(:api_tokens)
  end
end
