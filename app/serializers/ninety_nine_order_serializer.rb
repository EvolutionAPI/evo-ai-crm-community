# frozen_string_literal: true

module NinetyNineOrderSerializer
  extend self

  def serialize(order)
    {
      id: order.id,
      external_order_id: order.external_order_id,
      status: order.status,
      customer_name: order.customer_name,
      customer_phone: order.customer_phone,
      items: order.items || [],
      items_count: order.items_count,
      total_price: order.total_price&.to_f,
      raw_payload: order.raw_payload,
      received_at: order.received_at&.iso8601,
      created_at: order.created_at&.iso8601
    }
  end

  def serialize_collection(orders)
    return [] unless orders

    orders.map { |order| serialize(order) }
  end
end
