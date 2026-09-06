# frozen_string_literal: true

class CreateRecurringTransactions < ActiveRecord::Migration[7.1]
  def change
    create_table :recurring_transactions, id: :uuid do |t|
      t.string :kind, null: false
      t.string :scope, null: false
      t.string :description, null: false
      t.string :category
      t.decimal :amount, precision: 12, scale: 2, null: false, default: 0.0
      t.date :start_date, null: false
      t.string :frequency, null: false, default: 'monthly'
      t.integer :interval_days
      t.string :end_rule, null: false, default: 'never'
      t.date :end_date
      t.integer :max_occurrences
      t.boolean :active, null: false, default: true
      t.timestamps
    end

    add_index :recurring_transactions, :active
    add_index :recurring_transactions, :kind

    add_reference :financial_transactions, :recurring_transaction, type: :uuid, null: true
    add_column :financial_transactions, :occurrence_number, :integer
    add_index :financial_transactions, [:recurring_transaction_id, :occurrence_number],
              name: 'index_financial_transactions_on_recurrence_and_occurrence'
  end
end
