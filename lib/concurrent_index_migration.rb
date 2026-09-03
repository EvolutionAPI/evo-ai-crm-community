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
# Include in a migration that declares `disable_ddl_transaction!` (both the
# build and the drop refuse to run inside a transaction) and use
# `add_index_concurrently` instead of `add_index ... algorithm: :concurrently`.
# The name is mandatory: the guard looks the index up by name.
module ConcurrentIndexMigration
  def add_index_concurrently(table_name, column_name, name:, **)
    drop_invalid_index(name)
    add_index table_name, column_name, name: name, algorithm: :concurrently, if_not_exists: true, **
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
end
