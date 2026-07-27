# frozen_string_literal: true

# EVO-2207: one index per source of a captured lead, or the read scans the two largest
# tables in the CRM. `jsonb_path_ops` indexes containment only, which is all `@>` asks.
# The existing GIN on custom_fields does NOT serve `->>` equality, hence the expression
# index; partial because only lead-captured cards carry the key.
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

  # A failed CONCURRENTLY build leaves the index behind marked INVALID, and `if_not_exists`
  # would then skip it on every retry. Clearing it is what makes the retry rebuild.
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
