# Cliente da API oficial de parceiros da 99Food ("Protocolo 99 Alimentos"),
# confirmado na documentação real do parceiro em
# https://developer-food.99app.com/pt-BR/openapi (portal autenticado — não é
# o protocolo genérico "Open Delivery"). client_id/client_secret ficam só no
# backend (GlobalConfigService), nunca expostos ao frontend.
#
# A 99Food usa DOIS mecanismos de autenticação distintos:
# - v1 (loja/menu/pedidos/logística): auth_token obtido via app_id+app_secret
#   +app_shop_id, enviado como parâmetro (query no GET, body no POST) — NÃO é
#   um Bearer header.
# - v3 (financeiro): accessToken JWT obtido via app_id("retailer")+app_secret
#   ("secret"), enviado como header "Authorization: Bearer <token>".
class NinetyNine::Client
  BASE_URL = 'https://openapi.99food.com'
  AUTH_TOKEN_CACHE_KEY = 'ninety_nine:auth_token'
  FINANCE_TOKEN_CACHE_KEY = 'ninety_nine:finance_access_token'

  class Error < StandardError; end

  def self.configured?
    client_id.present? && client_secret.present? && store_id.present?
  end

  # Credenciais mínimas pra iniciar a conexão (gerar o link de autorização e
  # listar lojas vinculadas) — não exige store_id ainda, já que é isso que o
  # fluxo de conexão descobre.
  def self.credentials_configured?
    client_id.present? && client_secret.present?
  end

  def self.client_id
    GlobalConfigService.load('NINETY_NINE_CLIENT_ID', nil)
  end

  def self.client_secret
    GlobalConfigService.load('NINETY_NINE_CLIENT_SECRET', nil)
  end

  # app_shop_id — identificador da loja no NOSSO sistema, escolhido por nós
  # (não é atribuído pela 99Food), usado pra vincular a loja no /auth/authtoken/get.
  def self.store_id
    GlobalConfigService.load('NINETY_NINE_STORE_ID', nil)
  end

  # --- Loja / Menu / Pedidos / Logística (v1, auth_token) -----------------

  def store_details
    get_v1('/v1/shop/shop/detail')
  end

  def set_store_status(payload)
    post_v1('/v1/shop/shop/setStatus', payload)
  end

  def valid_categories
    get_v1('/v1/shop/shop/validCategories')
  end

  def menu
    get_v1('/v1/item/item/list')
  end

  def update_item_status(item_id, status)
    post_v1('/v1/item/item/updateItemStatus', { item_id: item_id, status: status })
  end

  def order_details(order_id)
    get_v1('/v1/order/order/detail', order_id: order_id)
  end

  def confirm_order(order_id)
    post_v1('/v1/order/order/confirm', order_id: order_id)
  end

  def cancel_order(order_id, reason_code:, reason: nil)
    post_v1('/v1/order/order/cancel', { order_id: order_id, reason_code: reason_code, reason: reason }.compact)
  end

  def ready_order(order_id)
    post_v1('/v1/order/order/ready', order_id: order_id)
  end

  def delivered_order(order_id)
    post_v1('/v1/order/order/delivered', order_id: order_id)
  end

  def dispatch_self_delivery(order_id, courier_info:, limit_time:, vehicle: nil, delivery_fee: nil)
    post_v1('/v1/order/selfdelivery/dispatch', {
              order_id: order_id,
              courier_info: courier_info,
              vehicle: vehicle,
              limit_time: limit_time,
              delivery_fee: delivery_fee
            }.compact)
  end

  # --- Conexão da loja (fluxo self-service, igual ao "Conectar com Google") --
  #
  # 1. #authorization_url gera um link (válido por 7 dias) que o dono da loja
  #    abre, faz login na 99Food e autoriza uma das lojas que ele administra.
  # 2. Depois disso, #bound_stores lista as lojas já vinculadas ao nosso
  #    app_id — cada uma já vem com o app_shop_id que vamos salvar como
  #    NINETY_NINE_STORE_ID.

  def authorization_url
    raise Error, 'Credenciais da 99Food não configuradas (App ID, App Secret).' unless self.class.credentials_configured?

    response = HTTParty.post(
      "#{BASE_URL}/v1/auth/authorizationpage/getUrl",
      body: { app_id: self.class.client_id }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
    handle_v1(response)['url']
  end

  def bound_stores(page_no: 1, page_size: 50)
    raise Error, 'Credenciais da 99Food não configuradas (App ID, App Secret).' unless self.class.credentials_configured?

    timestamp = Time.now.to_i
    params = { app_id: self.class.client_id, timestamp: timestamp, page_no: page_no, page_size: page_size }
    response = HTTParty.post(
      "#{BASE_URL}/v1/shop/shop/list",
      body: params.merge(sign: build_signature(params)).to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
    handle_v1(response)['shops'] || []
  end

  # --- Financeiro (v3, accessToken Bearer) ---------------------------------

  def bill_data(start_date:, end_date:, page_no: 1, page_size: 100)
    post_v3('/v3/finance/finance/getShopBillDetail', {
              acceptor_code: self.class.store_id,
              start_date: start_date,
              end_date: end_date,
              page_no: page_no,
              page_size: page_size
            })
  end

  def settlements_data(start_date:, end_date:, page_no: 1, page_size: 100)
    post_v3('/v3/finance/finance/getShopBillWeek', {
              acceptor_code: self.class.store_id,
              start_date: start_date,
              end_date: end_date,
              page_no: page_no,
              page_size: page_size
            })
  end

  private

  # Algoritmo de assinatura exigido por endpoints como /shop/shop/list e
  # /auth/authorization/shopBind: ordena os parâmetros por chave (ASCII),
  # concatena "chave=valor&chave=valor", acrescenta o app_secret no final
  # (sem separador) e tira o MD5 — confirmado na documentação oficial.
  def build_signature(params)
    sorted = params.sort.to_h
    to_sign = "#{sorted.map { |k, v| "#{k}=#{v}" }.join('&')}#{self.class.client_secret}"
    Digest::MD5.hexdigest(to_sign)
  end

  # --- v1: auth_token como parâmetro de requisição -------------------------

  def auth_token
    Rails.cache.fetch(AUTH_TOKEN_CACHE_KEY, expires_in: 20.minutes) { fetch_auth_token }
  end

  def fetch_auth_token
    raise Error, 'Credenciais da 99Food não configuradas (Client ID, Client Secret, ID da Loja).' unless self.class.configured?

    response = HTTParty.get(
      "#{BASE_URL}/v1/auth/authtoken/get",
      query: {
        app_id: self.class.client_id,
        app_secret: self.class.client_secret,
        app_shop_id: self.class.store_id
      }
    )
    body = handle_v1(response)
    body['auth_token']
  end

  def get_v1(path, extra_params = {})
    response = HTTParty.get("#{BASE_URL}#{path}", query: { auth_token: auth_token }.merge(extra_params))
    handle_v1(response)
  end

  def post_v1(path, payload)
    response = HTTParty.post(
      "#{BASE_URL}#{path}",
      body: { auth_token: auth_token }.merge(payload).to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
    handle_v1(response)
  end

  def handle_v1(response)
    raise Error, "Erro de rede na API da 99Food: #{response.code}" unless response.code.between?(200, 299)

    body = JSON.parse(response.body)
    errno = body['errno']
    raise Error, "Erro na API da 99Food (errno #{errno}): #{body['errmsg']}" unless errno.zero?

    body['data']
  end

  # --- v3: accessToken Bearer (só financeiro) ------------------------------

  def finance_access_token
    Rails.cache.fetch(FINANCE_TOKEN_CACHE_KEY, expires_in: 5.hours) { fetch_finance_token }
  end

  def fetch_finance_token
    raise Error, 'Credenciais da 99Food não configuradas (Client ID, Client Secret).' unless self.class.configured?

    response = HTTParty.post(
      "#{BASE_URL}/v3/auth/authtoken/signIn",
      body: { retailer: self.class.client_id, secret: self.class.client_secret }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
    raise Error, "Falha na autenticação financeira 99Food: #{response.code} #{response.body}" unless response.success?

    JSON.parse(response.body)['accessToken']
  end

  def post_v3(path, payload)
    response = HTTParty.post(
      "#{BASE_URL}#{path}",
      body: payload.to_json,
      headers: { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{finance_access_token}" }
    )
    handle_v1(response)
  end
end
