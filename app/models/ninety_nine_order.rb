# == Schema Information
#
# Table name: ninety_nine_orders
#
#  id                :uuid             not null, primary key
#  customer_name     :string(255)
#  customer_phone    :string(40)
#  items             :jsonb            not null
#  raw_payload       :jsonb            not null
#  received_at       :datetime         not null
#  status            :string(30)
#  total_price       :decimal(10, 2)
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  external_order_id :string(100)
#
# Indexes
#
#  index_ninety_nine_orders_on_external_order_id  (external_order_id)
#  index_ninety_nine_orders_on_received_at        (received_at)
#
class NinetyNineOrder < ApplicationRecord
  # Espelho dos eventos recebidos via webhook da 99 (99Food). Cada POST vira
  # uma linha nova — sem upsert, porque ainda não sabemos com certeza qual
  # campo identifica um pedido de forma estável nesse payload.
  scope :order_by_recent, -> { order(received_at: :desc) }

  def items_count
    items.to_a.sum { |item| item['quantity'].to_i }
  end
end
