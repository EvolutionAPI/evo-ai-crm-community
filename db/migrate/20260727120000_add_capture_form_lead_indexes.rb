# frozen_string_literal: true

# EVO-2207: a form's captured leads are derived from two sources, and each one needs its
# own index or the read degrades into a scan of the two largest tables in the CRM:
#
#   * the durable contact stamp — `contacts.custom_attributes @> {capture_form_slugs: [slug]}`
#     (EVO-2200). `jsonb_path_ops` is the smaller, faster GIN opclass for `@>`: it indexes
#     containment only, not key-existence, which is all this query asks.
#   * the legacy attribution still living on the card — `pipeline_items.custom_fields ->
#     'lead_metadata' ->> 'form_slug'`. The existing GIN on `custom_fields` does NOT serve
#     this predicate (a jsonb_ops GIN answers `@>` and `?`, not `->>` equality), so it needs
#     an expression index. Partial on IS NOT NULL: only lead-captured cards carry the key,
#     a small slice of the table, and `expr = 'slug'` implies the predicate so the planner
#     can still use it.
#
# Both are built CONCURRENTLY so they do not lock writes on populated tables.
class AddCaptureFormLeadIndexes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  CONTACTS_INDEX = 'index_contacts_on_custom_attributes'
  ITEMS_INDEX    = 'index_pipeline_items_on_lead_form_slug'
  ITEMS_EXPR     = "(custom_fields -> 'lead_metadata' ->> 'form_slug')"

  def up
    drop_invalid_index(CONTACTS_INDEX)
    add_index :contacts, :custom_attributes,
              using: :gin, opclass: :jsonb_path_ops,
              name: CONTACTS_INDEX, algorithm: :concurrently, if_not_exists: true

    drop_invalid_index(ITEMS_INDEX)
    add_index :pipeline_items, ITEMS_EXPR,
              name: ITEMS_INDEX, where: "#{ITEMS_EXPR} IS NOT NULL",
              algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :pipeline_items, name: ITEMS_INDEX, algorithm: :concurrently, if_exists: true
    remove_index :contacts, name: CONTACTS_INDEX, algorithm: :concurrently, if_exists: true
  end

  private

  # A CONCURRENTLY build that fails (deadlock, cancelled statement) leaves the index in
  # place marked INVALID — unused by the planner and invisible in normal output. On the
  # retry `if_not_exists` sees the name and skips, so the index would stay broken forever.
  # Clearing the invalid leftover first is what makes the retry actually rebuild it.
  def drop_invalid_index(name)
    invalid = select_value(<<~SQL.squish)
      SELECT 1 FROM pg_class i
      JOIN pg_index x ON x.indexrelid = i.oid
      WHERE i.relname = #{quote(name)} AND NOT x.indisvalid
    SQL
    return if invalid.blank?

    execute "DROP INDEX CONCURRENTLY IF EXISTS #{quote_column_name(name)}"
  end
end
