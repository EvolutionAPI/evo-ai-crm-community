# frozen_string_literal: true

# == Schema Information
#
# Table name: financial_transactions
#
#  id                       :uuid             not null, primary key
#  amount                   :decimal(12, 2)   default(0.0), not null
#  category                 :string
#  description              :string           not null
#  kind                     :string           not null
#  occurrence_number        :integer
#  receipt_url              :string
#  scope                    :string           not null
#  transaction_date         :datetime         not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  recurring_transaction_id :uuid
#
# Indexes
#
#  index_financial_transactions_on_kind                       (kind)
#  index_financial_transactions_on_recurrence_and_occurrence  (recurring_transaction_id,occurrence_number)
#  index_financial_transactions_on_recurring_transaction_id   (recurring_transaction_id)
#  index_financial_transactions_on_scope                      (scope)
#  index_financial_transactions_on_transaction_date           (transaction_date)
#
class FinancialTransaction < ApplicationRecord
  KINDS = %w[expense income].freeze
  SCOPES = %w[store personal].freeze

  belongs_to :recurring_transaction, optional: true

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :scope, presence: true, inclusion: { in: SCOPES }
  validates :description, presence: true, length: { maximum: 255 }
  validates :amount, numericality: { greater_than: 0 }
  validates :transaction_date, presence: true

  scope :by_scope, ->(scope) { where(scope: scope) if scope.present? }
  scope :by_kind, ->(kind) { where(kind: kind) if kind.present? }
  scope :ordered_recent, -> { order(transaction_date: :desc, created_at: :desc) }
end
