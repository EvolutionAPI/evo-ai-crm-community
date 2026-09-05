# frozen_string_literal: true

# `evo_core_custom_mcp_servers`, from the Go migration 000003 (plus
# `credential_refs` from 000021). See EvoCoreCustomToolsTable.
module EvoCoreCustomMcpServersTable
  module_function

  def create!
    connection = ActiveRecord::Base.connection
    connection.execute('CREATE EXTENSION IF NOT EXISTS "uuid-ossp"')
    return if connection.table_exists?(:evo_core_custom_mcp_servers)

    connection.create_table :evo_core_custom_mcp_servers, id: false do |t|
      t.column :id, :uuid, null: false, default: -> { 'uuid_generate_v4()' }
      t.string :name, null: false
      t.text :description
      t.string :url, null: false
      t.json :headers, null: false
      t.jsonb :credential_refs, null: false, default: {}
      t.integer :timeout, null: false, default: 0
      t.integer :retry_count, null: false, default: 0
      t.boolean :is_active, default: true
      t.timestamps
    end

    connection.execute('ALTER TABLE evo_core_custom_mcp_servers ADD PRIMARY KEY (id)')
  end

  def drop!
    ActiveRecord::Base.connection.drop_table(:evo_core_custom_mcp_servers, if_exists: true)
  end
end
