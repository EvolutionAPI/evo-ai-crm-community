module Api
  module V1
    module GestorPosts
      class CommentsController < BaseController
        before_action :require_social_channel!

        def index
          render json: { success: true, data: service.list(params.require(:post_id)) }
        rescue ::Instagram::CommentsService::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def reply
          data = service.reply(comment_id: params.require(:comment_id), text: params.require(:text))
          render json: { success: true, data: data }
        rescue ::Instagram::CommentsService::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        private

        def service
          @service ||= ::Instagram::CommentsService.new(channel: social_channel)
        end
      end
    end
  end
end
