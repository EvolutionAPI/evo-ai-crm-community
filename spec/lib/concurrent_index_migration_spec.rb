# frozen_string_literal: true

require 'rails_helper'

# Runs outside the transactional fixtures (CREATE/DROP INDEX CONCURRENTLY refuse a
# transaction) on a scratch table. The INVALID state is forged with `UPDATE
# pg_index`, which needs a superuser (the CI Postgres is one); those examples
# skip loudly on a restricted role.
RSpec.describe ConcurrentIndexMigration do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:table) { :crm402_scratch }
  let(:index_name) { 'index_crm402_scratch_on_value' }
  let(:other_schema) { 'crm402_other' }
  let(:migration_class) do
    Class.new(ActiveRecord::Migration[7.1]) do
      include ConcurrentIndexMigration
      disable_ddl_transaction!
    end
  end
  let(:migration) { migration_class.new.tap { |m| m.verbose = false } }

  before do
    connection.execute("DROP TABLE IF EXISTS #{table}")
    connection.execute("CREATE TABLE #{table} (id serial PRIMARY KEY, value text)")
  end

  after do
    connection.execute("DROP TABLE IF EXISTS #{table}")
    connection.execute("DROP SCHEMA IF EXISTS #{other_schema} CASCADE")
  end

  def superuser?
    connection.select_value('SELECT rolsuper FROM pg_roles WHERE rolname = current_user')
  end

  # Resolved through search_path, like DROP INDEX; nil when absent.
  def index_valid?
    connection.select_value(<<~SQL.squish)
      SELECT x.indisvalid FROM pg_index x WHERE x.indexrelid = to_regclass(#{connection.quote(index_name)})
    SQL
  end

  def forge_invalid(regclass)
    skip 'forging an INVALID index needs a superuser role (UPDATE pg_index)' unless superuser?
    connection.execute("UPDATE pg_index SET indisvalid = false WHERE indexrelid = #{connection.quote(regclass)}::regclass")
  end

  # Only the catalog flag is flipped; the on-disk index stays, as after a
  # lock-timed-out build.
  def leave_invalid_index
    migration.add_index_concurrently table, :value, name: index_name
    forge_invalid(index_name)
    expect(index_valid?).to be(false)
  end

  describe '#add_index_concurrently' do
    it 'creates the index valid on a clean table' do
      migration.add_index_concurrently table, :value, name: index_name
      expect(index_valid?).to be(true)
    end

    it 'rebuilds an INVALID leftover instead of skipping it (the bug)' do
      leave_invalid_index

      migration.add_index_concurrently table, :value, name: index_name

      expect(index_valid?).to be(true)
    end

    it 'is idempotent on a valid index (retry after success is a no-op)' do
      migration.add_index_concurrently table, :value, name: index_name
      oid = connection.select_value("SELECT #{connection.quote(index_name)}::regclass::oid")

      migration.add_index_concurrently table, :value, name: index_name

      expect(connection.select_value("SELECT #{connection.quote(index_name)}::regclass::oid")).to eq(oid)
      expect(index_valid?).to be(true)
    end

    it 'forwards index options (unique + partial)' do
      migration.add_index_concurrently table, :value, name: index_name, unique: true, where: 'value IS NOT NULL'

      definition = connection.select_value("SELECT indexdef FROM pg_indexes WHERE indexname = #{connection.quote(index_name)}")
      expect(definition).to include('UNIQUE', 'WHERE (value IS NOT NULL)')
    end

    it 'requires a name (the guard looks the index up by name)' do
      expect { migration.add_index_concurrently(table, :value) }.to raise_error(ArgumentError, /name/)
    end

    it 'rejects algorithm/if_not_exists overrides (they would silently defeat the guard)' do
      expect { migration.add_index_concurrently(table, :value, name: index_name, algorithm: :default) }
        .to raise_error(ArgumentError, /algorithm/)
      expect { migration.add_index_concurrently(table, :value, name: index_name, if_not_exists: false) }
        .to raise_error(ArgumentError, /if_not_exists/)
    end
  end

  describe '#drop_invalid_index' do
    it 'leaves a valid index alone' do
      migration.add_index_concurrently table, :value, name: index_name
      migration.drop_invalid_index(index_name)
      expect(index_valid?).to be(true)
    end

    it 'is a no-op for a name that does not exist' do
      expect { migration.drop_invalid_index('index_crm402_nope') }.not_to raise_error
    end

    it 'ignores a same-name INVALID index in another schema (DROP INDEX would not resolve to it)' do
      migration.add_index_concurrently table, :value, name: index_name
      connection.execute("CREATE SCHEMA #{other_schema}")
      connection.execute("CREATE TABLE #{other_schema}.#{table} (id serial PRIMARY KEY, value text)")
      connection.execute("CREATE INDEX #{index_name} ON #{other_schema}.#{table} (value)")
      forge_invalid("#{other_schema}.#{index_name}")

      migration.drop_invalid_index(index_name)

      expect(index_valid?).to be(true)
    end
  end

  # The contrast that motivates the helper: bare add_index with if_not_exists
  # walks past the invalid leftover, so a "successful" retry ships a dead index.
  it 'documents the failure mode of bare add_index ... if_not_exists' do
    leave_invalid_index

    migration.add_index table, :value, name: index_name, algorithm: :concurrently, if_not_exists: true

    expect(index_valid?).to be(false)
  end
end
