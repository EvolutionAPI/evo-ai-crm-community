# frozen_string_literal: true

class AddIndexToContactsType < ActiveRecord::Migration[7.1]
  include ConcurrentIndexMigration

  disable_ddl_transaction!

  INDEX_NAME = 'index_contacts_on_type'

  def up
    add_index_concurrently :contacts, :type, name: INDEX_NAME
  end

  def down
    remove_index :contacts, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
