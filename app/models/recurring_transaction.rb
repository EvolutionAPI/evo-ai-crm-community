# frozen_string_literal: true

# == Schema Information
#
# Table name: recurring_transactions
#
#  id              :uuid             not null, primary key
#  active          :boolean          default(TRUE), not null
#  amount          :decimal(12, 2)   default(0.0), not null
#  category        :string
#  description     :string           not null
#  end_date        :date
#  end_rule        :string           default("never"), not null
#  frequency       :string           default("monthly"), not null
#  interval_days   :integer
#  kind            :string           not null
#  max_occurrences :integer
#  scope           :string           not null
#  start_date      :date             not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_recurring_transactions_on_active  (active)
#  index_recurring_transactions_on_kind    (kind)
#
class RecurringTransaction < ApplicationRecord
  KINDS = %w[expense income].freeze
  SCOPES = %w[store personal].freeze
  FREQUENCIES = %w[monthly days].freeze
  END_RULES = %w[never until_date count].freeze

  # For `end_rule: never` we only materialize occurrences up to this far in the
  # future; `materialize_all!` is called on list requests so the window slides.
  GENERATION_HORIZON = 12.months
  MAX_GENERATION_CAP = 240

  has_many :financial_transactions, dependent: :nullify

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :scope, presence: true, inclusion: { in: SCOPES }
  validates :description, presence: true, length: { maximum: 255 }
  validates :amount, numericality: { greater_than: 0 }
  validates :start_date, presence: true
  validates :frequency, presence: true, inclusion: { in: FREQUENCIES }
  validates :end_rule, presence: true, inclusion: { in: END_RULES }
  validates :interval_days,
            numericality: { only_integer: true, greater_than: 0 },
            if: -> { frequency == 'days' }
  validates :end_date, presence: true, if: -> { end_rule == 'until_date' }
  validates :max_occurrences,
            numericality: { only_integer: true, greater_than: 0 },
            if: -> { end_rule == 'count' }
  validate :end_date_not_before_start, if: -> { end_rule == 'until_date' && end_date.present? }

  scope :active, -> { where(active: true) }

  def self.materialize_all!
    active.find_each(&:generate_occurrences!)
  end

  def monthly?
    frequency == 'monthly'
  end

  # Date of the nth occurrence (1-based). Monthly steps clamp to month ends
  # (Jan 31 -> Feb 28) via Date#>>.
  def occurrence_date(number)
    base = start_date.to_date
    return nil if number.nil? || number < 1
    return base >> (number - 1) if monthly?

    base + interval_days.to_i * (number - 1)
  end

  # Total occurrences that should exist given the end rule. For open-ended
  # recurrences it counts everything up to `upto`.
  def target_count(upto: Date.current + GENERATION_HORIZON)
    case end_rule
    when 'count'
      [[max_occurrences.to_i, MAX_GENERATION_CAP].min, 0].max
    when 'until_date'
      count_dates_while { |date| date <= end_date }
    else
      limit = upto.to_date
      count_dates_while { |date| date <= limit }
    end
  end

  def finished?
    return false unless active?
    return target_count <= existing_count if end_rule != 'never'

    false
  end

  def next_occurrence_date
    return nil unless active?
    return nil if target_count <= existing_count

    next_number = existing_max_occurrence + 1
    return nil if next_number > MAX_GENERATION_CAP

    candidate = occurrence_date(next_number)
    return nil if candidate.nil?
    return nil if end_rule == 'until_date' && candidate > end_date

    candidate
  end

  # Idempotent: creates every missing occurrence between 1..target_count.
  def generate_occurrences!
    return unless active?

    target = target_count
    return if target <= 0

    existing_numbers = financial_transactions.pluck(:occurrence_number).compact
    missing = (1..target).reject { |n| existing_numbers.include?(n) }
    return if missing.empty?

    now = Time.current
    missing.each do |number|
      financial_transactions.create!(
        kind: kind,
        scope: scope,
        description: description,
        category: category,
        amount: amount,
        transaction_date: occurrence_datetime(number),
        occurrence_number: number,
        created_at: now,
        updated_at: now
      )
    end
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # After a template update: drop not-yet-arrived occurrences so they are
  # regenerated with the new values; past ones stay as history.
  def regenerate_future!
    financial_transactions.where('transaction_date > ?', Time.current).destroy_all
    generate_occurrences!
  end

  private

  def count_dates_while
    n = 0
    while n < MAX_GENERATION_CAP
      date = occurrence_date(n + 1)
      break if date.nil? || !yield(date)

      n += 1
    end
    n
  end

  def existing_count
    financial_transactions.count
  end

  def existing_max_occurrence
    financial_transactions.maximum(:occurrence_number).to_i
  end

  # Noon UTC keeps the same calendar day in every timezone from UTC-11 to UTC+11,
  # matching how the SPA groups transactions by local day.
  def occurrence_datetime(number)
    occurrence_date(number).noon
  end

  def end_date_not_before_start
    errors.add(:end_date, 'must be on or after start date') if end_date < start_date.to_date
  end
end
