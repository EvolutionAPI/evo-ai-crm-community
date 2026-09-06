module Api
  module V1
    class NinetyNineController < Api::V1::BaseController
      # URL do webhook + token, pra configurar no painel de parceiros da 99.
      # Gera o token automaticamente na primeira vez que essa tela é aberta.
      def webhook_info
        token = GlobalConfigService.load('NINETY_NINE_WEBHOOK_SECRET', nil)
        if token.blank?
          token = SecureRandom.hex(24)
          GlobalConfig.set('NINETY_NINE_WEBHOOK_SECRET', token)
        end

        backend_url = ENV['BACKEND_URL'].to_s.strip.presence || request.base_url

        render json: {
          success: true,
          data: {
            webhook_url: "#{backend_url}/api/v1/webhooks/ninety_nine/#{token}",
            orders_received: NinetyNineOrder.count
          }
        }
      end

      def index
        render json: { success: true, data: NinetyNineOrderSerializer.serialize_collection(NinetyNineOrder.order_by_recent.limit(100)) }
      end
    end
  end
end
