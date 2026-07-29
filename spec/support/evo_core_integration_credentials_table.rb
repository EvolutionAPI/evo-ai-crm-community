# frozen_string_literal: true

# `evo_core_integration_credentials` is created by the Go migration 000019 of
# evo-ai-core-service and is deliberately absent from `db/schema.rb`. Specs that
# touch Ai::IntegrationCredential build it through this helper so the column set
# stays in one place (same arrangement as EvoCoreApiKeysTable).
module EvoCoreIntegrationCredentialsTable
  module_function

  def create!
    connection = ActiveRecord::Base.connection
    connection.execute('CREATE EXTENSION IF NOT EXISTS "uuid-ossp"')
    return if connection.table_exists?(:evo_core_integration_credentials)

    connection.create_table :evo_core_integration_credentials, id: false do |t|
      t.column :id, :uuid, null: false, default: -> { 'uuid_generate_v4()' }
      t.string :name, null: false
      t.string :provider, null: false
      t.string :kind, null: false, default: 'static'
      t.text :value
      t.string :value_format, null: false, default: 'scalar'
      t.string :value_hint
      t.string :scope, null: false, default: 'account'
      t.boolean :is_active, null: false, default: true
      t.string :owner_store
      t.string :owner_ref
      t.string :imported_from
      t.timestamps
    end

    add_constraints!(connection)
  end

  # Mirrors the Go migration: real primary key, and unique per scope — never
  # on name alone.
  def add_constraints!(connection)
    connection.execute('ALTER TABLE evo_core_integration_credentials ADD PRIMARY KEY (id)')
    connection.add_index :evo_core_integration_credentials, %i[scope name], unique: true
  end

  def drop!
    ActiveRecord::Base.connection.drop_table(:evo_core_integration_credentials, if_exists: true)
  end
end
