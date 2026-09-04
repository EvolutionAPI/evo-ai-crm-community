# frozen_string_literal: true

# Guard for `CREATE INDEX CONCURRENTLY` in migrations.
#
# A CONCURRENTLY build that fails midway (lock timeout, cancelled deploy) leaves
# the index behind marked INVALID: Postgres never uses it, `\d` does not flag
# it, and `add_index ... if_not_exists: true` on the retry sees a name that
# exists, skips the build and lets Rails record the migration as applied. That
# is how index_pipeline_items_on_purchase_identity shipped invalid on
# 2026-08-29. Dropping the invalid leftover first is what makes a retry rebuild.
#
# The build itself has to wait for every transaction that touches the table
# before it can start, so under live traffic it is the first thing a
# `lock_timeout` cancels — the same deploy failed twice on exactly that before
# passing on the third pod restart. Here the wait is bounded PER ATTEMPT by an
# explicit session lock_timeout and the build is retried in-process, with the
# invalid leftover cleared in between: a busy window costs a few retries, not
# a Job restart that replays every earlier migrate step. When the attempts run
# out the error propagates and the migration stays unapplied — never a
# recorded migration with a dead index. Moving index builds out of the deploy
# path altogether is the next step if this ever proves insufficient.
#
# Ceiling with the defaults: 6 attempts × 30s of lock wait + backoff of
# 5+10+15+20+25s ≈ 4m15s per index before giving up. Each wait is one
# statement, so it sits under the 600s statement_timeout of the migrate step;
# raise MIGRATION_INDEX_LOCK_TIMEOUT / _ATTEMPTS with that ceiling in mind.
# Only 55P03 (lock_not_available) is retried: a build cancelled by
# statement_timeout raises QueryCanceled and propagates — waiting longer would
# not help a build that is itself too slow.
#
# Include in a migration that declares `disable_ddl_transaction!` (both the
# build and the drop refuse to run inside a transaction) and use
# `add_index_concurrently` instead of `add_index ... algorithm: :concurrently`.
# The name is mandatory: the guard looks the index up by name.
module ConcurrentIndexMigration
  DEFAULT_LOCK_TIMEOUT = '30s'
  DEFAULT_ATTEMPTS = 6
  RETRY_BACKOFF_SECONDS = 5

  # `lock_timeout:` / `attempts:` override the env defaults; every other option
  # goes to add_index untouched.
  def add_index_concurrently(table_name, column_name, name:, **options)
    lock_timeout = options.delete(:lock_timeout) || ENV.fetch('MIGRATION_INDEX_LOCK_TIMEOUT', DEFAULT_LOCK_TIMEOUT)
    # A misconfigured env (blank, "abc") must not silently disable the retry: floor at one attempt.
    attempts = [(options.delete(:attempts) || ENV.fetch('MIGRATION_INDEX_LOCK_ATTEMPTS', DEFAULT_ATTEMPTS)).to_i, 1].max

    with_lock_timeout(lock_timeout) do
      retrying_on_lock_timeout(name, attempts) do
        drop_invalid_index(name)
        add_index table_name, column_name, name: name, algorithm: :concurrently, if_not_exists: true, **options
      end
    end
  end

  def drop_invalid_index(name)
    invalid = select_value(<<~SQL.squish)
      SELECT 1 FROM pg_class i
      JOIN pg_index x ON x.indexrelid = i.oid
      WHERE i.relname = #{quote(name)} AND NOT x.indisvalid
    SQL
    return if invalid.blank?

    say "dropping invalid index #{name} left by a failed CONCURRENTLY build"
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{quote_column_name(name)}"
  end

  private

  # Session-level SET (no transaction to scope a SET LOCAL to); restored on the
  # way out so the rest of the migration run keeps whatever it had.
  def with_lock_timeout(value)
    previous = select_value('SHOW lock_timeout')
    execute "SET lock_timeout = #{quote(value)}"
    yield
  ensure
    execute "SET lock_timeout = #{quote(previous)}" if previous
  end

  # 55P03 (lock_not_available) is what a lock_timeout cancellation raises; the
  # retry gives the build another window between the transactions it waits on.
  def retrying_on_lock_timeout(name, attempts)
    attempt = 1
    begin
      yield
    rescue ActiveRecord::LockWaitTimeout
      raise if attempt >= attempts

      say "lock timeout building #{name} (attempt #{attempt}/#{attempts}); retrying"
      sleep(RETRY_BACKOFF_SECONDS * attempt)
      attempt += 1
      retry
    end
  end
end
