class CreateFinancialTransactions < ActiveRecord::Migration[7.1]
  def change
    create_table :financial_transactions, id: :uuid do |t|
      t.string :kind, null: false
      t.string :scope, null: false
      t.string :description, null: false
      t.string :category
      t.decimal :amount, precision: 12, scale: 2, null: false, default: 0.0
      t.datetime :transaction_date, null: false
      t.timestamps
    end
    add_index :financial_transactions, :scope
    add_index :financial_transactions, :kind
    add_index :financial_transactions, :transaction_date
  end
end