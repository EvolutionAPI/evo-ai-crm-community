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
      t.string :imported_from
      t.boolean :is_active, null: false, default: true
      t.timestamps
    end

    # Mirrors idx_evo_core_api_keys_name_unique from the Go migration 000005:
    # a name collision is a database error, not a cosmetic detail.
    connection.add_index :evo_core_api_keys, :name, unique: true
  end

  def drop!
    ActiveRecord::Base.connection.drop_table(:evo_core_api_keys, if_exists: true)
  end
end
