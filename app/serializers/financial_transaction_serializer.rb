# frozen_string_literal: true

# FinancialTransactionSerializer - Optimized serialization for FinancialTransaction resources.
#
# Plain Ruby module for Oj direct serialization, matching the convention
# used by CannedResponseSerializer / ProductSerializer in this app.
module FinancialTransactionSerializer
  extend self

  def serialize(transaction)
    {
      id: transaction.id,
      kind: transaction.kind,
      scope: transaction.scope,
      description: transaction.description,
      category: transaction.category,
      amount: transaction.amount.to_f,
      transaction_date: transaction.transaction_date&.iso8601,
      receipt_url: transaction.receipt_url,
      recurring_transaction_id: transaction.recurring_transaction_id,
      occurrence_number: transaction.occurrence_number,
      created_at: transaction.created_at&.iso8601,
      updated_at: transaction.updated_at&.iso8601
    }
  end

  def serialize_collection(transactions)
    return [] unless transactions

    transactions.map { |transaction| serialize(transaction) }
  end
end