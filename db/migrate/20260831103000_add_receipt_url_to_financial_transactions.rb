class AddReceiptUrlToFinancialTransactions < ActiveRecord::Migration[7.1]
  def change
    add_column :financial_transactions, :receipt_url, :string
  end
end
