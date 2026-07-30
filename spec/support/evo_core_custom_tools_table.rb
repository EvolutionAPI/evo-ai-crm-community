# frozen_string_literal: true

# `evo_core_custom_tools` is created by the Go migration 000002 of
# evo-ai-core-service (plus `credential_refs` from 000021) and is deliberately
# absent from `db/schema.rb`. Specs build it here so the column set stays in one
# place (same arrangement as EvoCoreIntegrationCredentialsTable).
module EvoCoreCustomToolsTable
  module_function

  def create! # rubocop:disable Metrics/MethodLength -- mirrors the Go migration column for column
    connection = ActiveRecord::Base.connection
    connection.execute('CREATE EXTENSION IF NOT EXISTS "uuid-ossp"')
    return if connection.table_exists?(:evo_core_custom_tools)

    connection.create_table :evo_core_custom_tools, id: false do |t|
      t.column :id, :uuid, null: false, default: -> { 'uuid_generate_v4()' }
      t.string :name, null: false
      t.text :description
      t.string :method, null: false
      t.string :endpoint, null: false
      t.json :headers, null: false
      t.jsonb :credential_refs, null: false, default: {}
      t.json :path_params, null: false
      t.json :query_params, null: false
      t.json :body_params, null: false
      t.json :error_handling, null: false
      t.json :values, null: false
      t.boolean :is_active, default: true
      t.timestamps
    end

    connection.execute('ALTER TABLE evo_core_custom_tools ADD PRIMARY KEY (id)')
  end

  def drop!
    ActiveRecord::Base.connection.drop_table(:evo_core_custom_tools, if_exists: true)
  end
end
