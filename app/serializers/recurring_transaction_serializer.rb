# frozen_string_literal: true

# RecurringTransactionSerializer - Plain Ruby module for Oj direct serialization,
# matching FinancialTransactionSerializer conventions.
module RecurringTransactionSerializer
  extend self

  def serialize(recurrence)
    {
      id: recurrence.id,
      kind: recurrence.kind,
      scope: recurrence.scope,
      description: recurrence.description,
      category: recurrence.category,
      amount: recurrence.amount.to_f,
      start_date: recurrence.start_date&.iso8601,
      frequency: recurrence.frequency,
      interval_days: recurrence.interval_days,
      end_rule: recurrence.end_rule,
      end_date: recurrence.end_date&.iso8601,
      max_occurrences: recurrence.max_occurrences,
      active: recurrence.active,
      generated_count: recurrence.financial_transactions.count,
      next_occurrence_date: recurrence.next_occurrence_date&.iso8601,
      created_at: recurrence.created_at&.iso8601,
      updated_at: recurrence.updated_at&.iso8601
    }
  end

  def serialize_collection(recurrences)
    return [] unless recurrences

    recurrences.map { |recurrence| serialize(recurrence) }
  end
end
