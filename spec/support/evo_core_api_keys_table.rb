# frozen_string_literal: true

# `evo_core_api_keys` is created by the Go migrations of evo-ai-core-service and
# is deliberately absent from `db/schema.rb` — Rails does not own it. The test
# database therefore has no such table.
#
# Every spec that touches Ai::Credential builds it through this helper so the
# column set stays in one place: specs that declared their own copy drifted
# apart, and whichever ran last dropped the table the others expected.
module EvoCoreApiKeysTable
  module_function

  def create!
    connection = ActiveRecord::Base.connection
    connection.execute('CREATE EXTENSION IF NOT EXISTS "uuid-ossp"')
    return if connection.table_exists?(:evo_core_api_keys)

    connection.create_table :evo_core_api_keys, id: false do |t|
      t.column :id, :uuid, null: false, default: -> { 'uuid_generate_v4()' }
      t.string :name, null: false
      t.string :provider, null: false
      t.text :key, null: false
      t.string :key_hint, null: false, default: ''
      t.string :scope, null: false, default: 'account'
      # Mirrors migration 000018 EXACTLY, limit included: an unbounded column
      # here hid a real VARCHAR(64) overflow in the 1.5 migration.
      t.string :base_url, limit: 512
      t.string :imported_from, limit: 64
      t.boolean :is_active, null: false, default: true
      t.timestamps
    end

    # Mirrors idx_evo_core_api_keys_name_unique from the Go migration 000005:
    # a name collision is a database error, not a cosmetic detail.
    connection.add_index :evo_core_api_keys, :name, unique: true
    # Migration 000018 also puts a PARTIAL unique index on imported_from; without
    # it the idempotency tests rest only on the application-level exists? check.
    connection.add_index :evo_core_api_keys, :imported_from, unique: true,
                                                             where: 'imported_from IS NOT NULL',
                                                             name: 'idx_evo_core_api_keys_imported_from'
  end

  def drop!
    ActiveRecord::Base.connection.drop_table(:evo_core_api_keys, if_exists: true)
  end
end
