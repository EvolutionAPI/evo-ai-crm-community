# frozen_string_literal: true

module WorkOrderSerializer
  extend self

  def serialize(work_order)
    {
      id: work_order.id,
      os_number: work_order.os_number,
      status: work_order.status,
      client_name: work_order.client_name,
      client_cpf: work_order.client_cpf,
      client_phone: work_order.client_phone,
      client_email: work_order.client_email,
      client_instagram: work_order.client_instagram,
      client_gender: work_order.client_gender,
      client_birthdate: work_order.client_birthdate&.iso8601,
      client_cep: work_order.client_cep,
      client_address: work_order.client_address,
      client_number: work_order.client_number,
      client_neighborhood: work_order.client_neighborhood,
      client_city: work_order.client_city,
      client_state: work_order.client_state,
      device: work_order.device,
      problems: work_order.problems,
      checklist: work_order.checklist,
      observation: work_order.observation,
      device_password: work_order.device_password,
      entry_date: work_order.entry_date&.iso8601,
      pickup_date: work_order.pickup_date&.iso8601,
      device_turns_on: work_order.device_turns_on,
      picked_up: work_order.picked_up,
      items: work_order.items || [],
      items_count: work_order.items_count,
      item_names: work_order.item_names,
      base_value: work_order.base_value.to_f,
      discount: work_order.discount.to_f,
      total: work_order.total.to_f,
      payment_method: work_order.payment_method,
      installments: work_order.installments,
      created_at: work_order.created_at&.iso8601,
      updated_at: work_order.updated_at&.iso8601
    }
  end

  def serialize_collection(work_orders)
    return [] unless work_orders

    work_orders.map { |work_order| serialize(work_order) }
  end
end