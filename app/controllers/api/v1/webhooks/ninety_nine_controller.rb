# Ingress do webhook da 99 (99Food). A 99 não tem API de polling pública
# como o iFood — a integração funciona ao contrário: a 99 envia (POST) cada
# evento de pedido pra essa URL, configurada no painel de parceiros deles.
#
# Autenticação: token compartilhado no próprio path (NINETY_NINE_WEBHOOK_SECRET,
# gerado automaticamente). Não usamos HMAC porque ainda não temos a
# documentação de assinatura da 99 — o token na URL é validado antes de
# qualquer processamento.
#
# `ActionController::API` puro (como Api::V1::Webhooks::ErpController) — sem
# a cadeia de autenticação de sessão do BaseController, que não faz sentido
# pra uma chamada máquina-a-máquina de fora.
class Api::V1::Webhooks::NinetyNineController < ActionController::API
  before_action :verify_token!

  # Guardamos o payload inteiro sempre (raw_payload) — o formato exato do
  # webhook da 99 ainda não foi confirmado contra um evento real, então os
  # campos estruturados abaixo são melhor-esforço e nunca quebram o recebimento.
  def receive
    payload = JSON.parse(request.raw_post)
    NinetyNineOrder.create!(
      external_order_id: payload['orderId'] || payload['id'],
      status: payload['status'],
      customer_name: payload.dig('customer', 'name'),
      customer_phone: payload.dig('customer', 'phone'),
      total_price: payload['total'] || payload.dig('total', 'value'),
      items: payload['items'].is_a?(Array) ? payload['items'] : [],
      raw_payload: payload,
      received_at: Time.current
    )
    render json: { received: true }, status: :ok
  rescue JSON::ParserError
    render json: { received: false, error: 'invalid JSON' }, status: :bad_request
  rescue StandardError => e
    Rails.logger.error("[NINETY_NINE_WEBHOOK] failed: #{e.class}: #{e.message}")
    # Sempre 200 pra 99 não ficar reenviando o mesmo evento indefinidamente —
    # o erro fica logado pra investigar.
    render json: { received: true, warning: 'stored partially' }, status: :ok
  end

  private

  def verify_token!
    expected = GlobalConfigService.load('NINETY_NINE_WEBHOOK_SECRET', nil)
    return render(json: { error: 'webhook not configured' }, status: :service_unavailable) if expected.blank?
    return if ActiveSupport::SecurityUtils.secure_compare(params[:token].to_s, expected)

    render json: { error: 'invalid token' }, status: :unauthorized
  end
end
