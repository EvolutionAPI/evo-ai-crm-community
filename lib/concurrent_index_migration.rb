# frozen_string_literal: true

# A CONCURRENTLY build that fails midway leaves the index INVALID, and
# `add_index ... if_not_exists: true` then skips it on every retry; dropping the
# leftover first is what makes the retry rebuild. Include in a migration with
# `disable_ddl_transaction!`. The name is mandatory: the guard looks it up.
module ConcurrentIndexMigration
  RESERVED_OPTIONS = %i[algorithm if_not_exists].freeze

  def add_index_concurrently(table_name, column_name, name:, **options)
    reserved = options.keys & RESERVED_OPTIONS
    raise ArgumentError, "#{reserved.join(', ')} are set by add_index_concurrently" if reserved.any?

    drop_invalid_index(name)
    add_index table_name, column_name, name: name, algorithm: :concurrently, if_not_exists: true, **options
  end

  def drop_invalid_index(name)
    # to_regclass resolves through search_path, i.e. the relation DROP INDEX acts on.
    invalid = select_value(<<~SQL.squish)
      SELECT 1 FROM pg_index x
      WHERE x.indexrelid = to_regclass(#{quote(name)}) AND NOT x.indisvalid
    SQL
    return if invalid.blank?

    say "dropping invalid index #{name} left by a failed CONCURRENTLY build"
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{quote_column_name(name)}"
  end
end
