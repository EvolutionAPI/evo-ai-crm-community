module Api
  module V1
    class IfoodController < Api::V1::BaseController
      before_action :fetch_order, only: %i[confirm start_preparation ready_to_pickup dispatch_order cancel request_driver cancel_request_driver delivery_quote_for_order]

      # Status da conexão: credenciais configuradas + dados da loja vinculada
      # no iFood (nome, aberta/fechada).
      def status
        unless Ifood::Client.configured?
          render json: { success: true, data: { connected: false } }
          return
        end

        client = Ifood::Client.new
        merchant = client.merchants&.first
        # GET /merchants/:id/status devolve uma LISTA (uma entrada por
        # salesChannel, ex. ifood-app) — não um objeto único.
        statuses = merchant && client.merchant_status(merchant['id'])
        primary_status = statuses.is_a?(Array) ? statuses.first : statuses

        render json: {
          success: true,
          data: {
            connected: true,
            merchant_id: merchant && merchant['id'],
            merchant_name: merchant && merchant['name'],
            available: primary_status && primary_status['state'] == 'OK',
            status_message: primary_status && primary_status.dig('message', 'title')
          }
        }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Dispara o polling de eventos (grava/atualiza pedidos locais) e retorna
      # a lista atualizada.
      def sync
        Ifood::SyncOrdersService.new.call if Ifood::Client.configured?
        render json: { success: true, data: IfoodOrderSerializer.serialize_collection(IfoodOrder.order_by_recent) }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def index
        render json: { success: true, data: IfoodOrderSerializer.serialize_collection(IfoodOrder.order_by_recent) }
      end

      # Ações do pedido
      def confirm
        perform_order_action(new_status: 'CONFIRMED') { |client| client.confirm_order(@order.ifood_order_id) }
      end

      def start_preparation
        perform_order_action(new_status: 'PREPARATION_STARTED') { |client| client.start_preparation(@order.ifood_order_id) }
      end

      def ready_to_pickup
        perform_order_action(new_status: 'READY_TO_PICKUP') { |client| client.ready_to_pickup(@order.ifood_order_id) }
      end

      def dispatch_order
        perform_order_action(new_status: 'DISPATCHED') { |client| client.dispatch_order(@order.ifood_order_id) }
      end

      def cancel
        reason = params[:reason].presence || 'Cancelado pela loja'
        perform_order_action(new_status: 'CANCELLED') { |client| client.request_cancellation(@order.ifood_order_id, reason: reason) }
      end

      # Shipping — chama entregador parceiro pra este pedido (precisa do
      # quoteId de uma cotação feita antes, ver #delivery_quote).
      def request_driver
        quote_id = params.require(:quote_id)
        client = Ifood::Client.new
        client.request_driver(@order.ifood_order_id, quote_id: quote_id)
        render json: { success: true, message: 'Solicitação registrada — acompanhe pelo status do pedido.' }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def cancel_request_driver
        Ifood::Client.new.cancel_request_driver(@order.ifood_order_id)
        render json: { success: true }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Handshake Platform — responder disputa pós-entrega aberta pelo cliente.
      def accept_dispute
        data = Ifood::Client.new.accept_dispute(
          params.require(:dispute_id),
          reason: params.require(:reason),
          detail_reason: params[:detail_reason]
        )
        render json: { success: true, data: data }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def reject_dispute
        data = Ifood::Client.new.reject_dispute(
          params.require(:dispute_id),
          reason: params.require(:reason),
          detail_reason: params[:detail_reason]
        )
        render json: { success: true, data: data }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Status & Pausas da loja
      def interruptions
        render json: { success: true, data: Ifood::Client.new.interruptions }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def create_interruption
        minutes = params[:minutes].to_i
        minutes = 30 if minutes <= 0
        start_at = Time.current
        end_at = start_at + minutes.minutes
        data = Ifood::Client.new.create_interruption(
          description: params.require(:description),
          start_at: start_at,
          end_at: end_at
        )
        render json: { success: true, data: data }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def destroy_interruption
        Ifood::Client.new.delete_interruption(params[:id])
        render json: { success: true }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Dados cadastrais da loja (razão social, endereço, tipo de operação) +
      # tempo médio de preparo, pra exibir no topo de Status & Pausas.
      def merchant_details
        client = Ifood::Client.new
        details = client.merchant_details
        prep_minutes = begin
          client.preparation_time&.dig('avgTimeInMinutes') || client.preparation_time&.dig('time')
        rescue Ifood::Client::Error
          nil
        end
        render json: {
          success: true,
          data: {
            merchant_id: details['id'],
            name: details['name'],
            corporate_name: details['corporateName'],
            address: details['address'],
            operations: details['operations'],
            preparation_time_minutes: prep_minutes
          }
        }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # "Fechar loja agora" — cria uma pausa a partir de agora. Exige motivo
      # (a API do iFood usa esse texto como descrição da pausa).
      def close_store
        minutes = params[:minutes].presence&.to_i || 1440
        data = Ifood::Client.new.close_store(description: params.require(:reason), minutes: minutes)
        render json: { success: true, data: data }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # "Reabrir loja" — remove qualquer pausa ativa neste exato momento.
      def open_store
        Ifood::Client.new.open_store
        render json: { success: true }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Cardápio (leitura + criação de categoria — ver nota em Ifood::Client)
      def categories
        client = Ifood::Client.new
        catalog = client.catalogs.first
        data = catalog ? client.categories(catalog['catalogId']) : []
        render json: { success: true, data: data, meta: { catalog_id: catalog && catalog['catalogId'] } }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def create_category
        client = Ifood::Client.new
        catalog = client.catalogs.first
        return render json: { success: false, errors: ['Nenhum catálogo encontrado'] }, status: :unprocessable_entity unless catalog

        data = client.create_category(catalog['catalogId'], name: params.require(:name))
        render json: { success: true, data: data }, status: :created
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def update_category
        data = Ifood::Client.new.update_category(params[:id], name: params.require(:name))
        render json: { success: true, data: data }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def destroy_category
        Ifood::Client.new.delete_category(params[:id])
        render json: { success: true }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # GET de listagem geral ainda com bug de paginação não resolvido na API
      # do iFood — degrada pra lista vazia em vez de quebrar a tela. Preferir
      # #menu_items pra exibir o cardápio (usa a listagem por categoria, que
      # funciona normalmente).
      def products
        render json: { success: true, data: Ifood::Client.new.products }
      rescue Ifood::Client::Error
        render json: { success: true, data: [] }
      end

      # Cadastro do produto em si (nome/descrição) — vínculo com categoria e
      # preço ("item") é feito à parte, ver #create_item.
      def create_product
        data = Ifood::Client.new.create_product(
          name: params.require(:name),
          description: params[:description]
        )
        render json: { success: true, data: data }, status: :created
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Vincula produto + categoria + preço — isso é o que efetivamente
      # aparece no cardápio pro cliente (ver nota em Ifood::Client#create_item).
      def create_item
        data = Ifood::Client.new.create_item(
          product_id: params.require(:product_id),
          category_id: params.require(:category_id),
          price_value: params.require(:price_value)
        )
        render json: { success: true, data: data }, status: :created
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Tabela do cardápio pra exibição na tela — uma linha por item
      # (produto + categoria + preço + status), montada a partir da
      # listagem por categoria (confiável, ao contrário de #products).
      def menu_items
        client = Ifood::Client.new
        catalog = client.catalogs.first
        return render(json: { success: true, data: [] }) unless catalog

        categories = client.categories(catalog['catalogId'])
        rows = categories.flat_map do |cat|
          result = client.category_items(cat['id'])
          products_by_id = (result['products'] || []).index_by { |p| p['id'] }
          (result['items'] || []).map do |item|
            product = products_by_id[item['productId']] || {}
            {
              item_id: item['id'],
              product_id: item['productId'],
              category_id: cat['id'],
              category_name: cat['name'],
              name: product['name'],
              description: product['description'],
              price: item.dig('price', 'value'),
              status: item['status']
            }
          end
        end
        render json: { success: true, data: rows }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Edita o item de uma linha do cardápio. Nome/descrição vão pro
      # produto; preço/status recriam o item (ver nota em
      # Ifood::Client#update_item sobre por que o PATCH direto não funciona).
      def update_menu_item
        client = Ifood::Client.new
        if params[:name].present?
          client.update_product(params.require(:product_id), name: params[:name], description: params[:description])
        end
        if params[:price_value].present? || params[:status].present?
          client.update_item(
            category_id: params.require(:category_id),
            product_id: params.require(:product_id),
            price_value: params[:price_value] || params.require(:current_price),
            status: params[:status].presence || 'AVAILABLE'
          )
        end
        render json: { success: true }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Remove a linha inteira do cardápio: desvincula o item e apaga o
      # cadastro do produto.
      def destroy_menu_item
        client = Ifood::Client.new
        category_id = params.require(:category_id)
        product_id = params.require(:product_id)
        client.delete_item(category_id, product_id)
        client.delete_product(product_id)
        render json: { success: true }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Shipping — cotação de entrega parceira pra um endereço (lat/lng).
      def delivery_quote
        lat = params.require(:latitude)
        lng = params.require(:longitude)
        data = Ifood::Client.new.delivery_quote(latitude: lat, longitude: lng)
        render json: { success: true, data: data }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Mesma cotação, resolvida a partir do endereço de um pedido real do
      # iFood já sincronizado no CRM — não precisa digitar lat/lng.
      def delivery_quote_for_order
        data = Ifood::Client.new.delivery_quote_for_order(@order.ifood_order_id)
        render json: { success: true, data: data }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Analytics — KPIs de pedidos. Requer o escopo "analytics" liberado
      # pelo iFood nas credenciais do app; sem ele, retorna 403 (não é bug —
      # ver Ifood::Client#order_kpis).
      def analytics
        begin_date = params[:begin_date].presence || 30.days.ago.to_date.iso8601
        end_date = params[:end_date].presence || Date.current.iso8601
        data = Ifood::Client.new.order_kpis(begin_date: begin_date, end_date: end_date)
        render json: { success: true, data: data }
      rescue Ifood::Client::Error => e
        forbidden = e.message.include?('403')
        render json: { success: false, forbidden: forbidden, errors: [e.message] }, status: :bad_gateway
      end

      # Financeiro — extrato de repasses (settlements) e vendas do período
      # (default: últimos 7 dias; a API do iFood limita "sales" a 8 dias).
      def settlements
        begin_date = params[:begin_date].presence || 7.days.ago.to_date.iso8601
        end_date = params[:end_date].presence || Date.current.iso8601
        data = Ifood::Client.new.settlements(begin_date: begin_date, end_date: end_date)
        render json: { success: true, data: data }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def sales
        begin_date = params[:begin_date].presence || 7.days.ago.to_date.iso8601
        end_date = params[:end_date].presence || Date.current.iso8601
        data = Ifood::Client.new.sales(begin_date: begin_date, end_date: end_date)
        render json: { success: true, data: data || { sales: [] } }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Arquivo de conciliação do mês (competence). 404 quando o iFood ainda
      # não gerou o arquivo pro mês — estado válido, não erro.
      def reconciliation
        competence = params[:competence].presence || Date.current.strftime('%Y-%m')
        data = Ifood::Client.new.reconciliation(competence: competence)
        render json: { success: true, data: data }
      rescue Ifood::Client::Error => e
        if e.message.include?('404')
          render json: { success: true, data: nil, message: 'Nenhum arquivo de conciliação para esse mês' }
        else
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end
      end

      def anticipations
        begin_date = params[:begin_date].presence || 30.days.ago.to_date.iso8601
        end_date = params[:end_date].presence || Date.current.iso8601
        data = Ifood::Client.new.anticipations(begin_date: begin_date, end_date: end_date)
        render json: { success: true, data: data }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def financial_events
        begin_date = params[:begin_date].presence || 30.days.ago.to_date.iso8601
        end_date = params[:end_date].presence || Date.current.iso8601
        data = Ifood::Client.new.financial_events(begin_date: begin_date, end_date: end_date)
        render json: { success: true, data: data }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Avaliações da loja
      def reviews
        data = Ifood::Client.new.reviews(page: params[:page].presence || 1)
        render json: { success: true, data: data }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Nota agregada — 404 quando a loja ainda não tem nenhuma avaliação,
      # estado válido (não erro) numa loja de teste sem pedidos reais.
      def review_summary
        data = Ifood::Client.new.review_summary
        render json: { success: true, data: data }
      rescue Ifood::Client::Error => e
        if e.message.include?('404')
          render json: { success: true, data: nil }
        else
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end
      end

      def reply_review
        Ifood::Client.new.reply_review(params[:id], text: params.require(:text))
        render json: { success: true }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      private

      def fetch_order
        @order = IfoodOrder.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { success: false, errors: ['Pedido não encontrado'] }, status: :not_found
      end

      def perform_order_action(new_status:)
        client = Ifood::Client.new
        yield(client)
        @order.update!(status: new_status)
        render json: { success: true, data: IfoodOrderSerializer.serialize(@order) }
      rescue Ifood::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end
    end
  end
end
