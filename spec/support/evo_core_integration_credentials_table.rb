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

    create_columns!(connection)
    add_constraints!(connection)
  end

  def create_columns!(connection)
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
  end

  # Mirrors migration 000019 of the core service: primary key, uniqueness per
  # scope (never on name alone) AND the CHECK constraints.
  #
  # The CHECKs are not decoration here. Story 2.1 AC4 says an oauth row carries
  # no value "by construction", and the construction IS the database constraint.
  # A helper without them lets a spec insert a row the real schema rejects, so
  # the suite would go green against a schema where the invariant does not
  # exist — the same structural blindness the unique index had before.
  def add_constraints!(connection)
    connection.execute('ALTER TABLE evo_core_integration_credentials ADD PRIMARY KEY (id)')
    connection.add_index :evo_core_integration_credentials, %i[scope name], unique: true
    # ⚠️ `agency` is NOT in the Go migration: it is the enterprise link the
    # FR2 guard specs insert to prove the chain is extensible by insertion.
    # Constraining the test schema to the two community scopes would make the
    # database reject the very scenario story 1.2 exists to protect. The
    # community CHECK stays two-valued; this helper is deliberately wider.
    connection.execute(<<~SQL.squish)
      ALTER TABLE evo_core_integration_credentials
        ADD CONSTRAINT evo_core_integration_credentials_kind_check
          CHECK (kind IN ('static', 'oauth')),
        ADD CONSTRAINT evo_core_integration_credentials_value_format_check
          CHECK (value_format IN ('scalar', 'composite')),
        ADD CONSTRAINT evo_core_integration_credentials_scope_check
          CHECK (scope IN ('installation', 'agency', 'account')),
        ADD CONSTRAINT evo_core_integration_credentials_kind_content_check
          CHECK (
            (kind = 'static' AND value IS NOT NULL AND owner_store IS NULL AND owner_ref IS NULL)
            OR
            (kind = 'oauth' AND value IS NULL AND owner_store IS NOT NULL AND owner_ref IS NOT NULL)
          )
    SQL
  end

  def drop!
    ActiveRecord::Base.connection.drop_table(:evo_core_integration_credentials, if_exists: true)
  end
end
