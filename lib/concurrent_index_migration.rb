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
# Under live traffic the build waits on every transaction touching the table, so
# it is the first statement a lock_timeout cancels. Each attempt is bounded by a
# session lock_timeout and retried in-process, dropping the invalid leftover in
# between; when the attempts run out the error propagates and the migration
# stays unapplied. Only 55P03 is retried: QueryCanceled (statement_timeout)
# propagates. Defaults (6 × 30s + 5..25s backoff ≈ 4m15s per index) sit under
# the migrate step's 600s statement_timeout. Tune with MIGRATION_INDEX_LOCK_TIMEOUT
# (Postgres interval WITH unit, e.g. 30s) and MIGRATION_INDEX_LOCK_ATTEMPTS
# (positive integer).
#
# Include in a migration that declares `disable_ddl_transaction!` (both the
# build and the drop refuse to run inside a transaction) and use
# `add_index_concurrently` instead of `add_index ... algorithm: :concurrently`.
# The name is mandatory: the guard looks the index up by name.
module ConcurrentIndexMigration
  DEFAULT_LOCK_TIMEOUT = '30s'
  DEFAULT_ATTEMPTS = 6
  RETRY_BACKOFF_SECONDS = 5
  LOCK_TIMEOUT_FORMAT = /\A\d+\s*(us|ms|s|min|h|d)\z/

  # `lock_timeout:` / `attempts:` override the env values; every other option
  # goes to add_index untouched.
  def add_index_concurrently(table_name, column_name, name:, **options)
    lock_timeout = lock_timeout_setting(options.delete(:lock_timeout))
    attempts = attempts_setting(options.delete(:attempts))

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

  # Blank means unset. Anything else must carry a unit: Postgres reads a bare
  # number as milliseconds, so "60" would cancel every attempt after 60ms.
  def lock_timeout_setting(explicit)
    value = (explicit || ENV.fetch('MIGRATION_INDEX_LOCK_TIMEOUT', nil)).to_s.strip
    return DEFAULT_LOCK_TIMEOUT if value.empty?
    return value if value.match?(LOCK_TIMEOUT_FORMAT)

    raise ArgumentError, "MIGRATION_INDEX_LOCK_TIMEOUT=#{value.inspect}: expected a Postgres interval with unit, e.g. 30s"
  end

  # Blank means unset; anything that is not a positive integer falls back to the
  # default out loud instead of silently leaving a single attempt.
  def attempts_setting(explicit)
    value = (explicit || ENV.fetch('MIGRATION_INDEX_LOCK_ATTEMPTS', nil)).to_s.strip
    return DEFAULT_ATTEMPTS if value.empty?

    parsed = Integer(value, exception: false)
    return parsed if parsed&.positive?

    say "ignoring MIGRATION_INDEX_LOCK_ATTEMPTS=#{value.inspect} (not a positive integer); using #{DEFAULT_ATTEMPTS}"
    DEFAULT_ATTEMPTS
  end

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
