module Api
  module V1
    # GET/PUT por scope: editor-menus | dashboard-menu-items | site-menu-items
    # Config GLOBAL — uma linha por scope, compartilhada por todos os usuários
    # da instalação (ver MenuConfig). Payload é o JSON exato que o frontend
    # mantinha no localStorage.
    class MenuConfigsController < Api::V1::BaseController
      before_action :validate_scope!

      def show
        payload = MenuConfig.fetch_for(params[:scope])
        render json: { success: true, data: { scope: params[:scope], payload: payload || {} } }
      end

      def update
        raw = params[:payload].presence || {}
        # Deep-convert direto: não desempacotar seletivamente a chave `items`
        # antes de converter — fazer isso deixava hashes internos como
        # ActionController::Parameters não convertidos, quebrando a
        # serialização jsonb (mesma classe de bug já corrigida em
        # pipeline_items_controller#custom_fields_param).
        payload = raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h : raw

        record = MenuConfig.upsert_for!(params[:scope], payload, editor: current_user)
        render json: { success: true, data: { scope: record.scope, payload: record.payload } }
      rescue ActiveRecord::RecordInvalid => e
        render json: { success: false, errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      private

      def validate_scope!
        return if MenuConfig::SCOPES.include?(params[:scope])

        render json: {
          success: false,
          errors: ["scope inválido: use um de #{MenuConfig::SCOPES.join(', ')}"]
        }, status: :bad_request
      end
    end
  end
end
