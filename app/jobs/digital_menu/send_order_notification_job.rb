# frozen_string_literal: true

# Executa DigitalMenu::OrderNotificationService em background — o envio real
# (ContactInboxWithContactBuilder/ConversationBuilder/mensagem) pode demorar
# ou travar numa chamada de rede pro provider de WhatsApp, e isso nunca pode
# prender a resposta do checkout público. Grava o resultado (sent/failed) no
# Redis sob `order_token`, pra que o checkout público consiga consultar via
# polling e, se falhar, oferecer o fallback "enviar você mesmo pelo WhatsApp".
class DigitalMenu::SendOrderNotificationJob < ApplicationJob
  queue_as :default

  STATUS_TTL = 10.minutes

  def perform(order_token:, customer:, items:, payment_method:, notes:)
    result = DigitalMenu::OrderNotificationService.new(
      customer: customer,
      items: items,
      payment_method: payment_method,
      notes: notes
    ).call

    write_status(order_token, result.success ? 'sent' : 'failed')
  rescue StandardError => e
    write_status(order_token, 'failed')
    raise e
  end

  private

  def write_status(order_token, status)
    Redis::Alfred.setex("digital_menu_order_status:#{order_token}", status, STATUS_TTL)
  end
end
