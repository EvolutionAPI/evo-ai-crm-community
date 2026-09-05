# frozen_string_literal: true

# `evo_core_agent_integrations`, from the Go migration 000014. See
# EvoCoreCustomToolsTable. The unique (agent_id, provider) mirrors the real
# constraint: two agents may hold the same provider, one row each.
module EvoCoreAgentIntegrationsTable
  module_function

  def create!
    connection = ActiveRecord::Base.connection
    connection.execute('CREATE EXTENSION IF NOT EXISTS "uuid-ossp"')
    return if connection.table_exists?(:evo_core_agent_integrations)

    connection.create_table :evo_core_agent_integrations, id: false do |t|
      t.column :id, :uuid, null: false, default: -> { 'uuid_generate_v4()' }
      t.column :agent_id, :uuid, null: false
      t.string :provider, null: false
      t.jsonb :config, default: {}
      t.timestamps
    end

    connection.execute('ALTER TABLE evo_core_agent_integrations ADD PRIMARY KEY (id)')
    connection.add_index :evo_core_agent_integrations, %i[agent_id provider], unique: true
  end

  def drop!
    ActiveRecord::Base.connection.drop_table(:evo_core_agent_integrations, if_exists: true)
  end
end
