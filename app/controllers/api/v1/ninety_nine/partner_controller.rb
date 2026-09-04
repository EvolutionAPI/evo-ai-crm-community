module Api
  module V1
    module NinetyNine
      class PartnerController < Api::V1::BaseController
        before_action :check_connected, except: %i[status connect_url bound_stores]
        before_action :check_credentials, only: %i[connect_url bound_stores]

        def status
          render json: {
            success: true,
            data: { connected: ::NinetyNine::Client.configured?, store_id: ::NinetyNine::Client.store_id }
          }
        end

        # --- Conexão da loja (fluxo self-service) ------------------------

        def connect_url
          render json: { success: true, data: { url: client.authorization_url } }
        rescue ::NinetyNine::Client::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def bound_stores
          render json: { success: true, data: client.bound_stores }
        rescue ::NinetyNine::Client::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        # --- Loja ---------------------------------------------------------

        def store_details
          render json: { success: true, data: client.store_details }
        rescue ::NinetyNine::Client::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def set_store_status
          payload = params.require(:payload).permit!.to_h
          render json: { success: true, data: client.set_store_status(payload) }
        rescue ::NinetyNine::Client::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        # --- Cardápio -------------------------------------------------------

        def menu
          render json: { success: true, data: client.menu }
        rescue ::NinetyNine::Client::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def update_item_status
          render json: { success: true, data: client.update_item_status(params.require(:item_id), params.require(:status)) }
        rescue ::NinetyNine::Client::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        # --- Pedidos ---------------------------------------------------------

        def order_details
          render json: { success: true, data: client.order_details(params.require(:order_id)) }
        rescue ::NinetyNine::Client::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def confirm_order
          render json: { success: true, data: client.confirm_order(params.require(:order_id)) }
        rescue ::NinetyNine::Client::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def cancel_order
          data = client.cancel_order(params.require(:order_id), reason_code: params.require(:reason_code), reason: params[:reason])
          render json: { success: true, data: data }
        rescue ::NinetyNine::Client::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def ready_order
          render json: { success: true, data: client.ready_order(params.require(:order_id)) }
        rescue ::NinetyNine::Client::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def delivered_order
          render json: { success: true, data: client.delivered_order(params.require(:order_id)) }
        rescue ::NinetyNine::Client::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        # --- Financeiro -------------------------------------------------------

        def bill_data
          data = client.bill_data(start_date: params.require(:start_date), end_date: params.require(:end_date), page_no: params[:page_no] || 1)
          render json: { success: true, data: data }
        rescue ::NinetyNine::Client::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def settlements_data
          data = client.settlements_data(start_date: params.require(:start_date), end_date: params.require(:end_date), page_no: params[:page_no] || 1)
          render json: { success: true, data: data }
        rescue ::NinetyNine::Client::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        private

        def client
          @client ||= ::NinetyNine::Client.new
        end

        def check_connected
          return if ::NinetyNine::Client.configured?

          render json: { success: false, errors: ['Integração da 99Food não configurada.'] }, status: :unprocessable_entity
        end

        def check_credentials
          return if ::NinetyNine::Client.credentials_configured?

          render json: { success: false, errors: ['Configure o App ID e o App Secret da 99Food primeiro.'] }, status: :unprocessable_entity
        end
      end
    end
  end
end
