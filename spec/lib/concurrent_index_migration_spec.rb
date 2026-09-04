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
    stub_const("#{described_class}::RETRY_BACKOFF_SECONDS", 0.2)
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

  # Live traffic: another session holds a lock the build has to wait on; the
  # session lock_timeout bounds each attempt and the retry catches the next window.
  describe 'lock contention (CRM-403)' do
    # Holds ACCESS EXCLUSIVE from a second connection for `seconds`, then releases;
    # the CONCURRENTLY build queues behind it and hits lock_timeout.
    def hold_table_lock(seconds)
      ready = Queue.new
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |other|
          other.transaction do
            other.execute("LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE")
            ready << true
            sleep seconds
          end
        end
      end
      ready.pop
      thread
    end

    it 'retries after a lock timeout and builds the index once the lock is released' do
      holder = hold_table_lock(3)

      migration.add_index_concurrently table, :value, name: index_name, lock_timeout: '500ms', attempts: 6
      holder.join

      expect(index_valid?).to be(true)
    end

    it 'gives up loudly when the attempts run out — the migration stays unapplied' do
      holder = hold_table_lock(4)

      expect do
        migration.add_index_concurrently table, :value, name: index_name, lock_timeout: '200ms', attempts: 2
      end.to raise_error(ActiveRecord::LockWaitTimeout)
      holder.join
    end

    it 'falls back to the default attempts, out loud, when MIGRATION_INDEX_LOCK_ATTEMPTS is not a positive integer' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('MIGRATION_INDEX_LOCK_ATTEMPTS', nil).and_return('abc')
      allow(migration).to receive(:say).and_call_original
      holder = hold_table_lock(2)

      migration.add_index_concurrently table, :value, name: index_name, lock_timeout: '100ms'
      holder.join

      expect(index_valid?).to be(true)
      expect(migration).to have_received(:say).with(/ignoring MIGRATION_INDEX_LOCK_ATTEMPTS="abc".*using 6/)
    end

    it 'restores the session lock_timeout afterwards, also on failure' do
      before = connection.select_value('SHOW lock_timeout')
      holder = hold_table_lock(2)
      begin
        migration.add_index_concurrently table, :value, name: index_name, lock_timeout: '100ms', attempts: 1
      rescue ActiveRecord::LockWaitTimeout
        nil
      end
      holder.join

      expect(connection.select_value('SHOW lock_timeout')).to eq(before)
    end

    it 'sets the per-attempt lock_timeout on the migration session while building' do
      seen = nil
      # Migration#add_index reaches the connection through method_missing, so
      # the observable seam is the connection itself.
      allow(connection).to receive(:add_index).and_wrap_original do |m, *args, **kw|
        seen = connection.select_value('SHOW lock_timeout')
        m.call(*args, **kw)
      end

      migration.add_index_concurrently table, :value, name: index_name, lock_timeout: '7s'

      expect(seen).to eq('7s')
    end

    it 'reads MIGRATION_INDEX_LOCK_TIMEOUT when no option is given, and falls back to 30s on blank' do
      allow(ENV).to receive(:fetch).and_call_original
      seen = []
      allow(connection).to receive(:add_index).and_wrap_original do |m, *args, **kw|
        seen << connection.select_value('SHOW lock_timeout')
        m.call(*args, **kw)
      end

      allow(ENV).to receive(:fetch).with('MIGRATION_INDEX_LOCK_TIMEOUT', nil).and_return('9s')
      migration.add_index_concurrently table, :value, name: index_name
      connection.execute("DROP INDEX #{index_name}")

      allow(ENV).to receive(:fetch).with('MIGRATION_INDEX_LOCK_TIMEOUT', nil).and_return('')
      migration.add_index_concurrently table, :value, name: index_name

      expect(seen).to eq(%w[9s 30s])
    end

    it 'rejects a lock_timeout without unit before touching the session (a bare number is milliseconds)' do
      before = connection.select_value('SHOW lock_timeout')

      expect do
        migration.add_index_concurrently table, :value, name: index_name, lock_timeout: '60'
      end.to raise_error(ArgumentError, /MIGRATION_INDEX_LOCK_TIMEOUT="60".*unit/)

      expect(connection.select_value('SHOW lock_timeout')).to eq(before)
      expect(index_valid?).to be_nil
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
