module Api
  module V1
    module GestorPosts
      class GalleryController < BaseController
        before_action :require_social_channel!

        def account_info
          render json: { success: true, data: service.account_info }
        rescue ::Instagram::GalleryService::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def media
          render json: { success: true, data: service.media(limit: (params[:limit] || 25).to_i) }
        rescue ::Instagram::GalleryService::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def demographics
          breakdown = params[:breakdown] == 'city' ? 'city' : 'age,gender'
          render json: { success: true, data: service.demographics(breakdown: breakdown) }
        rescue ::Instagram::GalleryService::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def peak_hours
          render json: { success: true, data: service.peak_online_hours }
        rescue ::Instagram::GalleryService::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        private

        def service
          @service ||= ::Instagram::GalleryService.new(channel: social_channel)
        end
      end
    end
  end
end
