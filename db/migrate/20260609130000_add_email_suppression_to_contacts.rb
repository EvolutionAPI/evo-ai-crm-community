# frozen_string_literal: true

class AddEmailSuppressionToContacts < ActiveRecord::Migration[7.1]
  def change
    add_column :contacts, :email_suppressed, :boolean, default: false, null: false
    add_column :contacts, :email_suppression_reason, :string
  end
end
