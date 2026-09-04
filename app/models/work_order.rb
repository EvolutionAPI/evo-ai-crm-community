# == Schema Information
#
# Table name: work_orders
#
#  id                  :uuid             not null, primary key
#  base_value          :decimal(10, 2)   default(0.0), not null
#  checklist           :text
#  client_address      :string(255)
#  client_birthdate    :date
#  client_cep          :string(20)
#  client_city         :string(100)
#  client_cpf          :string(20)
#  client_email        :string(255)
#  client_gender       :string(20)
#  client_instagram    :string(255)
#  client_name         :string(255)
#  client_neighborhood :string(100)
#  client_number       :string(20)
#  client_phone        :string(40)
#  client_state        :string(20)
#  device              :string(255)
#  device_password     :string(100)
#  device_turns_on     :boolean          default(TRUE), not null
#  discount            :decimal(10, 2)   default(0.0), not null
#  entry_date          :datetime
#  installments        :integer
#  items               :jsonb            not null
#  observation         :text
#  os_number           :string(50)       not null
#  payment_method      :string(40)       default("Não Definido"), not null
#  picked_up           :boolean          default(FALSE), not null
#  pickup_date         :date
#  problems            :text
#  status              :string(20)       default("open"), not null
#  total               :decimal(10, 2)   default(0.0), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
# Indexes
#
#  index_work_orders_on_client_name  (client_name)
#  index_work_orders_on_entry_date   (entry_date)
#  index_work_orders_on_items        (items) USING gin
#  index_work_orders_on_os_number    (os_number) UNIQUE
#  index_work_orders_on_status       (status)
#
class WorkOrder < ApplicationRecord
  STATUSES = %w[open in_progress waiting_parts done delivered cancelled].freeze
  PAYMENT_METHODS = ['Não Definido', 'Dinheiro', 'Cartão de Crédito', 'Cartão de Débito', 'PIX', 'Transferência'].freeze

  validates :os_number, presence: true, uniqueness: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :payment_method, presence: true, inclusion: { in: PAYMENT_METHODS }
  validates :base_value, numericality: { greater_than_or_equal_to: 0 }
  validates :discount, numericality: { greater_than_or_equal_to: 0 }
  validates :total, numericality: { greater_than_or_equal_to: 0 }

  scope :by_status, ->(status) { where(status: status) if status.present? }
  scope :by_payment_method, ->(method) { where(payment_method: method) if method.present? }
  scope :by_client, ->(term) do
    if term.present?
      normalized = term.to_s.strip
      where('client_name ILIKE :t OR client_cpf ILIKE :t OR client_phone ILIKE :t OR os_number ILIKE :t', t: "%#{normalized}%")
    end
  end
  scope :order_by_recent, -> { order(created_at: :desc) }

  def items_count
    items.to_a.sum { |item| item['quantity'].to_i }
  end

  def item_names
    items.to_a.map { |item| item['name'] }.compact.join(', ')
  end

  # Gera o próximo número de OS incrementando o maior existente (padrão OS-XXXX)
  def self.next_os_number
    current = order(Arel.sql('os_number DESC')).limit(1).pluck(:os_number).first
    number = current.to_s[/\d+/]&.to_i || 0
    "OS-#{(number + 1).to_s.rjust(4, '0')}"
  end
end
