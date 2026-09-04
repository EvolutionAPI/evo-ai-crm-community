# frozen_string_literal: true

require 'rails_helper'

# CRM-402: a CONCURRENTLY build that fails midway leaves an INVALID index that
# `if_not_exists: true` then skips forever. Runs OUTSIDE the transactional
# fixtures because neither CREATE nor DROP INDEX CONCURRENTLY can run inside a
# transaction; a scratch table keeps it off the app schema. The INVALID state
# is forged with `UPDATE pg_index`, which needs a SUPERUSER role (the CI
# Postgres is one); those examples skip, loudly, on a restricted role.
RSpec.describe ConcurrentIndexMigration do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:table) { :crm402_scratch }
  let(:index_name) { 'index_crm402_scratch_on_value' }
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

  after { connection.execute("DROP TABLE IF EXISTS #{table}") }

  def superuser?
    connection.select_value('SELECT rolsuper FROM pg_roles WHERE rolname = current_user')
  end

  def index_valid?
    connection.select_value(<<~SQL.squish)
      SELECT x.indisvalid FROM pg_class i JOIN pg_index x ON x.indexrelid = i.oid
      WHERE i.relname = #{connection.quote(index_name)}
    SQL
  end

  # What a lock-timed-out CONCURRENTLY build leaves behind: the catalog row with
  # indisvalid = false. Only the flag is flipped; the on-disk index is intact,
  # which is exactly the state the retry sees in production.
  def leave_invalid_index
    skip 'forging an INVALID index needs a superuser role (UPDATE pg_index)' unless superuser?
    migration.add_index_concurrently table, :value, name: index_name
    connection.execute("UPDATE pg_index SET indisvalid = false WHERE indexrelid = #{connection.quote(index_name)}::regclass")
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
  end

  # Live traffic: another session holds a lock the build has to wait on. The
  # session lock_timeout bounds each attempt and the retry catches the next
  # window — a Job restart is not needed.
  describe 'lock contention (CRM-403)' do
    # Holds ACCESS EXCLUSIVE on the scratch table from a second connection for
    # `hold` seconds, then releases. CREATE INDEX CONCURRENTLY needs SHARE UPDATE
    # EXCLUSIVE, so the build queues behind it and hits lock_timeout.
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
  end

  # The contrast that motivates the helper: bare add_index with if_not_exists
  # walks past the invalid leftover, so a "successful" retry ships a dead index.
  it 'documents the failure mode of bare add_index ... if_not_exists' do
    leave_invalid_index

    migration.add_index table, :value, name: index_name, algorithm: :concurrently, if_not_exists: true

    expect(index_valid?).to be(false)
  end
end
