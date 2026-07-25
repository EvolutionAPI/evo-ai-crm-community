# frozen_string_literal: true

# EVO-2207: the form-leads read derives from contacts stamped with the capture slug
# (`contacts.custom_attributes @> {capture_form_slugs: [slug]}`, EVO-2200). Without a
# GIN index that containment probe is a sequential scan on the largest table in the
# CRM, and it runs once per form on the forms list. `jsonb_path_ops` is the smaller,
# faster opclass for the `@>` containment operator (it indexes only containment, not
# key-existence, which is all this query needs). Built CONCURRENTLY so it does not
# lock writes on an already-populated table.
class AddGinIndexToContactsCustomAttributes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :contacts, :custom_attributes,
              using: :gin, opclass: :jsonb_path_ops,
              name: 'index_contacts_on_custom_attributes',
              algorithm: :concurrently, if_not_exists: true
  end
end
