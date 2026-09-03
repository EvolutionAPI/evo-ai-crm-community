# frozen_string_literal: true

# EVO-2207: one index per source of a captured lead, or the read scans the two largest
# tables in the CRM. `jsonb_path_ops` indexes containment only, which is all `@>` asks.
# The existing GIN on custom_fields does NOT serve `->>` equality, hence the expression
# index; partial because only lead-captured cards carry the key.
class AddCaptureFormLeadIndexes < ActiveRecord::Migration[7.1]
  include ConcurrentIndexMigration

  disable_ddl_transaction!

  CONTACTS_INDEX = 'index_contacts_on_custom_attributes'
  ITEMS_INDEX    = 'index_pipeline_items_on_lead_form_slug'
  ITEMS_EXPR     = "(custom_fields -> 'lead_metadata' ->> 'form_slug')"

  def up
    add_index_concurrently :contacts, :custom_attributes,
                           name: CONTACTS_INDEX, using: :gin, opclass: :jsonb_path_ops
    add_index_concurrently :pipeline_items, ITEMS_EXPR,
                           name: ITEMS_INDEX, where: "#{ITEMS_EXPR} IS NOT NULL"
  end

  def down
    remove_index :pipeline_items, name: ITEMS_INDEX, algorithm: :concurrently, if_exists: true
    remove_index :contacts, name: CONTACTS_INDEX, algorithm: :concurrently, if_exists: true
  end
end
