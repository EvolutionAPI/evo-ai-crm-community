# == Schema Information
#
# Table name: ifood_orders
#
#  id             :uuid             not null, primary key
#  customer_name  :string(255)
#  customer_phone :string(40)
#  items          :jsonb            not null
#  order_type     :string(30)
#  placed_at      :datetime
#  raw_payload    :jsonb            not null
#  status         :string(30)       default("PLACED"), not null
#  total_price    :decimal(10, 2)   default(0.0), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  display_id     :string(20)
#  ifood_order_id :string(100)      not null
#
# Indexes
#
#  index_ifood_orders_on_ifood_order_id  (ifood_order_id) UNIQUE
#  index_ifood_orders_on_placed_at       (placed_at)
#  index_ifood_orders_on_status          (status)
#
class IfoodOrder < ApplicationRecord
  # Espelho local dos eventos de pedido do iFood (Order API v1.0) — a API deles
  # só mantém eventos por uma janela curta via polling, então persistimos aqui
  # para a tela ter uma lista estável.
  STATUSES = %w[PLACED CONFIRMED PREPARATION_STARTED READY_TO_PICKUP DISPATCHED CONCLUDED CANCELLED].freeze

  validates :ifood_order_id, presence: true, uniqueness: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :total_price, numericality: { greater_than_or_equal_to: 0 }

  scope :order_by_recent, -> { order(placed_at: :desc, created_at: :desc) }

  def items_count
    items.to_a.sum { |item| item['quantity'].to_i }
  end
end
