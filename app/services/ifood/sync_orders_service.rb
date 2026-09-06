# Faz o polling de eventos do iFood, busca o detalhe de pedidos novos/alterados,
# grava/atualiza o espelho local (IfoodOrder) e confirma (acknowledge) os
# eventos processados — obrigatório no contrato da Order API para o iFood
# parar de reenviar o mesmo evento.
class Ifood::SyncOrdersService
  # code -> fullCode possíveis em eventos de pedido (nem todo evento é pedido;
  # eventos sem orderId, ex. de picking, são só confirmados e ignorados aqui).
  def initialize(client: Ifood::Client.new)
    @client = client
  end

  def call
    events = @client.poll_events
    return { processed: 0 } if events.blank?

    order_ids = events.filter_map { |e| e['orderId'] }.uniq
    order_ids.each { |id| sync_order(id) }

    @client.acknowledge(events.filter_map { |e| e['id'] })
    { processed: order_ids.size }
  end

  private

  def sync_order(ifood_order_id)
    payload = @client.order_details(ifood_order_id)
    return if payload.blank?

    order = IfoodOrder.find_or_initialize_by(ifood_order_id: ifood_order_id)
    order.assign_attributes(attributes_from(payload))
    order.save!
  rescue Ifood::Client::Error => e
    Rails.logger.error("iFood sync_order(#{ifood_order_id}) failed: #{e.message}")
  end

  def attributes_from(payload)
    customer = payload['customer'] || {}
    total = payload.dig('total', 'orderAmount') || payload.dig('total', 'value') || 0

    {
      display_id: payload['displayId'],
      status: payload['orderStatus'] || payload['status'] || 'PLACED',
      order_type: payload['orderType'],
      customer_name: customer['name'],
      customer_phone: customer.dig('phone', 'number'),
      items: (payload['items'] || []).map { |i| item_attrs(i) },
      total_price: total.to_f,
      placed_at: payload['createdAt'] || Time.current,
      raw_payload: payload
    }
  end

  def item_attrs(item)
    {
      'name' => item['name'],
      'quantity' => item['quantity'],
      'unitPrice' => item.dig('unitPrice', 'value') || item['unitPrice']
    }
  end
end
