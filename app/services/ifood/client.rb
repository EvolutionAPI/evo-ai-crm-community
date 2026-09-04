# Cliente da Order API v1.0 do iFood (Merchant API). Autenticação via
# client_credentials — client_id/client_secret ficam só no backend
# (GlobalConfigService/InstallationConfig), nunca expostos ao frontend.
class Ifood::Client
  BASE_URL = 'https://merchant-api.ifood.com.br'
  TOKEN_CACHE_KEY = 'ifood:access_token'

  class Error < StandardError; end

  def self.configured?
    client_id.present? && client_secret.present?
  end

  def self.client_id
    GlobalConfigService.load('IFOOD_CLIENT_ID', nil)
  end

  def self.client_secret
    GlobalConfigService.load('IFOOD_CLIENT_SECRET', nil)
  end

  def self.merchant_id
    GlobalConfigService.load('IFOOD_MERCHANT_ID', nil)
  end

  def access_token
    Rails.cache.fetch(TOKEN_CACHE_KEY, expires_in: 20.minutes) { fetch_token }
  end

  def merchants
    get('/merchant/v1.0/merchants')
  end

  def merchant_status(merchant_id = self.class.merchant_id)
    get("/merchant/v1.0/merchants/#{merchant_id}/status")
  end

  # GET /events:polling — janela curta de eventos pendentes (pedidos novos,
  # mudanças de status). Cada evento precisa ser confirmado via #acknowledge
  # ou o iFood reenvia depois.
  def poll_events
    get('/order/v1.0/events:polling') || []
  end

  def acknowledge(event_ids)
    return if event_ids.blank?

    post('/order/v1.0/events/acknowledgment', event_ids.map { |id| { id: id } })
  end

  def order_details(ifood_order_id)
    get("/order/v1.0/orders/#{ifood_order_id}")
  end

  # Ações do ciclo de vida do pedido (Order API v1.0) — todas POST sem corpo,
  # exceto o cancelamento.
  def confirm_order(ifood_order_id)
    post("/order/v1.0/orders/#{ifood_order_id}/confirm", nil)
  end

  def start_preparation(ifood_order_id)
    post("/order/v1.0/orders/#{ifood_order_id}/startPreparation", nil)
  end

  def ready_to_pickup(ifood_order_id)
    post("/order/v1.0/orders/#{ifood_order_id}/readyToPickup", nil)
  end

  def dispatch_order(ifood_order_id)
    post("/order/v1.0/orders/#{ifood_order_id}/dispatch", nil)
  end

  def request_cancellation(ifood_order_id, reason:, cancellation_code: '501')
    post("/order/v1.0/orders/#{ifood_order_id}/requestCancellation", { reason: reason, cancellationCode: cancellation_code })
  end

  # Shipping — chama um entregador parceiro do iFood para um pedido já
  # existente (usa o quoteId obtido em #delivery_quote, válido por ~24h).
  # Resposta 202 Accepted — a alocação é assíncrona, acompanhada por eventos
  # (REQUEST_DRIVER_SUCCESS / REQUEST_DRIVER_FAILED) via #poll_events.
  def request_driver(ifood_order_id, quote_id:)
    post("/shipping/v1.0/orders/#{ifood_order_id}/requestDriver", { quoteId: quote_id })
  end

  # Só funciona antes do entregador aceitar a corrida — depois disso segue
  # as regras normais de cancelamento de pedido.
  def cancel_request_driver(ifood_order_id)
    post("/shipping/v1.0/orders/#{ifood_order_id}/cancelRequestDriver", nil)
  end

  # Handshake Platform — responder a uma disputa pós-entrega aberta pelo
  # cliente. reason/detail_reason seguem os códigos documentados pelo iFood
  # (ex.: "CUSTOMER_SATISFACTION").
  def accept_dispute(dispute_id, reason:, detail_reason: nil)
    post("/order/v1.0/disputes/#{dispute_id}/accept", { reason: reason, detailReason: detail_reason }.compact)
  end

  def reject_dispute(dispute_id, reason:, detail_reason: nil)
    post("/order/v1.0/disputes/#{dispute_id}/reject", { reason: reason, detailReason: detail_reason }.compact)
  end

  # Status & Pausas da loja
  def interruptions(merchant_id = self.class.merchant_id)
    get("/merchant/v1.0/merchants/#{merchant_id}/interruptions") || []
  end

  def create_interruption(description:, start_at:, end_at:, merchant_id: self.class.merchant_id)
    post("/merchant/v1.0/merchants/#{merchant_id}/interruptions", {
           description: description,
           start: start_at.iso8601,
           end: end_at.iso8601
         })
  end

  def delete_interruption(interruption_id, merchant_id: self.class.merchant_id)
    delete("/merchant/v1.0/merchants/#{merchant_id}/interruptions/#{interruption_id}")
  end

  # Dados cadastrais da loja (nome fantasia, razão social, endereço, tipo de
  # operação) — confirmado contra a API real.
  def merchant_details(merchant_id = self.class.merchant_id)
    get("/merchant/v1.0/merchants/#{merchant_id}")
  end

  # Tempo médio de preparo. GET confirmado (404 quando ainda não configurado
  # pela loja — tratado no controller como "não configurado", não como erro).
  # Criar/editar via API não foi confirmado (o corpo aceito pelo endpoint não
  # bateu com as variações tentadas) — configurar continua sendo feito pelo
  # Portal do Parceiro por enquanto.
  def preparation_time(merchant_id = self.class.merchant_id)
    get("/merchant/v1.0/merchants/#{merchant_id}/myPreparationTime")
  end

  # "Fechar loja agora" / "reabrir loja" não têm um endpoint dedicado de
  # toggle no iFood — na prática isso é feito criando (fechar) ou removendo
  # (reabrir) uma pausa (#create_interruption / #delete_interruption) que
  # cobre o momento atual. `close_store` cria uma pausa a partir de agora;
  # `open_store` remove qualquer pausa que esteja ativa neste momento.
  def close_store(description:, minutes: 1440, merchant_id: self.class.merchant_id)
    create_interruption(
      description: description,
      start_at: Time.current,
      end_at: Time.current + minutes.minutes,
      merchant_id: merchant_id
    )
  end

  def open_store(merchant_id: self.class.merchant_id)
    now = Time.current
    interruptions(merchant_id).select do |i|
      begin
        Time.zone.parse(i['start']) <= now && now <= Time.zone.parse(i['end'])
      rescue ArgumentError, TypeError
        false
      end
    end.each { |i| delete_interruption(i['id'], merchant_id: merchant_id) }
  end

  # Cardápio — catálogo, categorias, produtos e itens (produto + categoria +
  # preço = o que aparece pro cliente).
  def catalogs(merchant_id = self.class.merchant_id)
    get("/catalog/v2.0/merchants/#{merchant_id}/catalogs") || []
  end

  def categories(catalog_id, merchant_id = self.class.merchant_id)
    get("/catalog/v2.0/merchants/#{merchant_id}/catalogs/#{catalog_id}/categories") || []
  end

  def create_category(catalog_id, name:, merchant_id: self.class.merchant_id)
    post("/catalog/v2.0/merchants/#{merchant_id}/catalogs/#{catalog_id}/categories", {
           name: name,
           status: 'AVAILABLE',
           index: 0,
           template: 'DEFAULT'
         })
  end

  def update_category(category_id, name:, status: 'AVAILABLE', index: 0, merchant_id: self.class.merchant_id)
    catalog_id = catalogs(merchant_id).first&.fetch('catalogId', nil)
    patch("/catalog/v2.0/merchants/#{merchant_id}/catalogs/#{catalog_id}/categories/#{category_id}", {
            name: name,
            status: status,
            index: index
          })
  end

  def delete_category(category_id, merchant_id: self.class.merchant_id)
    delete("/catalog/v2.0/merchants/#{merchant_id}/categories/#{category_id}")
  end

  # Lista os itens (produto + preço + status) já vinculados a uma categoria —
  # ao contrário de #products (listagem geral, com bug de paginação não
  # resolvido na API do iFood), este endpoint funciona normalmente e é a
  # forma confiável de montar a tabela do cardápio.
  def category_items(category_id, merchant_id: self.class.merchant_id)
    get("/catalog/v2.0/merchants/#{merchant_id}/categories/#{category_id}/items") || {}
  end

  # GET de listagem geral — mantido só por compatibilidade; ver nota acima
  # sobre o bug de paginação. Preferir #category_items.
  def products(merchant_id = self.class.merchant_id)
    get("/catalog/v2.0/merchants/#{merchant_id}/products") || []
  end

  # Cria o produto (nome/descrição) — só o cadastro em si, sem preço nem
  # categoria ainda. `serving` é obrigatório pelo iFood (ex.: "NOT_APPLICABLE").
  def create_product(name:, description: nil, serving: 'NOT_APPLICABLE', merchant_id: self.class.merchant_id)
    post("/catalog/v2.0/merchants/#{merchant_id}/products", {
           name: name,
           description: description,
           serving: serving,
           shifts: []
         }.compact)
  end

  # Edita nome/descrição do produto (não mexe em preço/categoria — isso é o
  # "item", ver #update_item). Confirmado contra a API real.
  def update_product(product_id, name:, description: nil, serving: 'NOT_APPLICABLE', merchant_id: self.class.merchant_id)
    put("/catalog/v2.0/merchants/#{merchant_id}/products/#{product_id}", {
          name: name,
          description: description,
          serving: serving,
          shifts: []
        }.compact)
  end

  def delete_product(product_id, merchant_id: self.class.merchant_id)
    delete("/catalog/v2.0/merchants/#{merchant_id}/products/#{product_id}")
  end

  # Associa um produto a uma categoria com preço — isso é o "item" que
  # efetivamente aparece no cardápio pro cliente. Confirmado contra a API
  # real (PUT, 200, item + optionGroups + products no retorno).
  def create_item(product_id:, category_id:, price_value:, merchant_id: self.class.merchant_id)
    put("/catalog/v2.0/merchants/#{merchant_id}/items", {
          item: {
            type: 'DEFAULT',
            categoryId: category_id,
            productId: product_id,
            status: 'AVAILABLE',
            price: { value: price_value },
            shifts: []
          }
        })
  end

  # Remove o vínculo produto+categoria (o "item" some do cardápio; o produto
  # em si continua existindo até #delete_product ser chamado também).
  def delete_item(category_id, product_id, merchant_id: self.class.merchant_id)
    delete("/catalog/v2.0/merchants/#{merchant_id}/categories/#{category_id}/products/#{product_id}")
  end

  # "Editar" preço/status de um item: o PATCH de merge documentado pelo
  # iFood (/{merchantId}/items/{itemId}) responde 200 mas, testado à
  # exaustão (price, status, contextModifiers, com/sem itemContextId), NUNCA
  # aplica a mudança de fato — parece não-operante nesta conta de teste. O
  # caminho que realmente funciona (confirmado) é excluir o item e recriar
  # com produto/categoria iguais e preço/status novos — o item ganha um novo
  # id, mas o produto e a categoria continuam os mesmos.
  def update_item(category_id:, product_id:, price_value:, status: 'AVAILABLE', merchant_id: self.class.merchant_id)
    delete_item(category_id, product_id, merchant_id: merchant_id)
    put("/catalog/v2.0/merchants/#{merchant_id}/items", {
          item: {
            type: 'DEFAULT',
            categoryId: category_id,
            productId: product_id,
            status: status,
            price: { value: price_value },
            shifts: []
          }
        })
  end

  # Analytics — KPIs de pedidos (GMV, contagem por forma de pagamento) num
  # período. referenceDate é filtrado por data de criação do pedido.
  def order_kpis(begin_date:, end_date:, merchant_id: self.class.merchant_id)
    post("/analytics/v1.0/merchants/#{merchant_id}/orders/kpis", {
           page: 1,
           size: 1,
           filter: { referenceDate: { gte: begin_date, lt: end_date } },
           agg: {
             metrics: { gmv: %w[sum avg min max] },
             terms: { paymentMethod: %w[count cardinality] }
           }
         })
  end

  # Shipping — cotação de entrega parceira do iFood para um endereço
  # (latitude/longitude). Testado e confirmado contra a API real.
  def delivery_quote(latitude:, longitude:, merchant_id: self.class.merchant_id)
    get("/shipping/v1.0/merchants/#{merchant_id}/deliveryAvailabilities?latitude=#{latitude}&longitude=#{longitude}")
  end

  # Mesma cotação, mas resolvida a partir do endereço de entrega de um
  # pedido já existente no iFood — não precisa digitar lat/lng na mão.
  def delivery_quote_for_order(ifood_order_id)
    get("/shipping/v1.0/orders/#{ifood_order_id}/deliveryAvailabilities")
  end

  # Financeiro (Conciliator) — extrato de repasses e vendas por período.
  def settlements(begin_date:, end_date:, merchant_id: self.class.merchant_id)
    get("/financial/v3.0/merchants/#{merchant_id}/settlements?beginPaymentDate=#{begin_date}&endPaymentDate=#{end_date}")
  end

  # A janela máxima aceita pelo iFood é de 8 dias — quem chama deve paginar
  # por conta própria para períodos maiores.
  def sales(begin_date:, end_date:, merchant_id: self.class.merchant_id)
    get("/financial/v3.0/merchants/#{merchant_id}/sales?beginSalesDate=#{begin_date}&endSalesDate=#{end_date}")
  end

  # Arquivo de conciliação de um mês fechado ("competence", formato yyyy-MM).
  # Confirmado contra a API real — 404 é resposta válida quando não existe
  # arquivo gerado pro mês (não é erro do nosso lado).
  def reconciliation(competence:, merchant_id: self.class.merchant_id)
    get("/financial/v3.0/merchants/#{merchant_id}/reconciliation?competence=#{competence}")
  end

  # Antecipações de recebíveis solicitadas pela loja. Parâmetro confirmado
  # contra a API real por tentativa — a doc oficial não deixa claro o nome
  # exato (begin/endCalculationDate, não begin/endPaymentDate como settlements/sales).
  def anticipations(begin_date:, end_date:, merchant_id: self.class.merchant_id)
    get("/financial/v3.0/merchants/#{merchant_id}/anticipations?beginCalculationDate=#{begin_date}&endCalculationDate=#{end_date}")
  end

  # Eventos financeiros (lançamentos individuais — taxas, repasses, ajustes)
  # no período. Confirmado contra a API real.
  def financial_events(begin_date:, end_date:, merchant_id: self.class.merchant_id)
    get("/financial/v3.0/merchants/#{merchant_id}/financial-events?beginDate=#{begin_date}&endDate=#{end_date}") || []
  end

  # Avaliações da loja (v1 foi descontinuada pelo iFood — usar v2).
  def reviews(page: 1, merchant_id: self.class.merchant_id)
    get("/review/v2.0/merchants/#{merchant_id}/reviews?page=#{page}")
  end

  # Nota agregada da loja (média + contagem de avaliações).
  def review_summary(merchant_id: self.class.merchant_id)
    get("/review/v2.0/merchants/#{merchant_id}/summary")
  end

  # Responder a uma avaliação de cliente.
  def reply_review(review_id, text:, merchant_id: self.class.merchant_id)
    post("/review/v2.0/merchants/#{merchant_id}/reviews/#{review_id}/answers", { text: text })
  end

  # Logistics — entrega feita com entregador PRÓPRIO da loja (não da malha
  # do iFood). Diferente de Shipping (#request_driver), que usa entregador
  # parceiro do iFood.
  def assign_driver(ifood_order_id, worker_name:, worker_phone:, worker_vehicle_type: 'MOTORCYCLE')
    post("/logistics/v1.0/orders/#{ifood_order_id}/assignDriver", {
           workerName: worker_name,
           workerPhone: worker_phone,
           workerVehicleType: worker_vehicle_type
         })
  end

  # Handshake Platform — propor uma alternativa (ex.: reembolso parcial) pra
  # uma disputa, em vez de aceitar/recusar direto. alternative_id vem do
  # payload do evento HANDSHAKE_DISPUTE — não é livre.
  def propose_dispute_alternative(dispute_id, alternative_id, type:, amount_value:, currency: 'BRL')
    post("/order/v1.0/disputes/#{dispute_id}/alternatives/#{alternative_id}", {
           type: type,
           metadata: { amount: { value: amount_value, currency: currency } }
         })
  end

  private

  def fetch_token
    raise Error, 'iFood client_id/client_secret não configurados' unless self.class.configured?

    response = HTTParty.post(
      "#{BASE_URL}/authentication/v1.0/oauth/token",
      body: URI.encode_www_form(
        grantType: 'client_credentials',
        clientId: self.class.client_id,
        clientSecret: self.class.client_secret
      ),
      headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }
    )
    raise Error, "Falha na autenticação iFood: #{response.code} #{response.body}" unless response.success?

    JSON.parse(response.body)['accessToken']
  end

  def get(path)
    response = HTTParty.get("#{BASE_URL}#{path}", headers: auth_headers)
    handle(response)
  end

  def post(path, body)
    response = HTTParty.post(
      "#{BASE_URL}#{path}",
      body: body.nil? ? nil : body.to_json,
      headers: body.nil? ? auth_headers : auth_headers.merge('Content-Type' => 'application/json')
    )
    handle(response)
  end

  def delete(path)
    response = HTTParty.delete("#{BASE_URL}#{path}", headers: auth_headers)
    handle(response)
  end

  def put(path, body)
    response = HTTParty.put(
      "#{BASE_URL}#{path}",
      body: body.to_json,
      headers: auth_headers.merge('Content-Type' => 'application/json')
    )
    handle(response)
  end

  def patch(path, body)
    response = HTTParty.patch(
      "#{BASE_URL}#{path}",
      body: body.to_json,
      headers: auth_headers.merge('Content-Type' => 'application/json')
    )
    handle(response)
  end

  def auth_headers
    { 'Authorization' => "Bearer #{access_token}" }
  end

  def handle(response)
    return nil if response.code == 204
    raise Error, "Erro na API do iFood #{response.code}: #{response.body}" unless response.success?
    return nil if response.body.blank?

    JSON.parse(response.body)
  end
end
