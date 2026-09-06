module Api
  module V1
    module GestorPosts
      class PublicationsController < BaseController
        before_action :require_social_channel!, only: [:create]

        def index
          uploads = ::GestorPosts::Upload.where(created_by: current_user.id).order(created_at: :desc).limit(50)
          render json: { success: true, data: uploads.as_json(only: %i[id caption platforms content_type status error_message external_post_ids created_at]) }
        end

        def show
          upload = ::GestorPosts::Upload.find(params[:id])
          render json: { success: true, data: upload.as_json(only: %i[id caption platforms content_type status error_message external_post_ids created_at]) }
        rescue ActiveRecord::RecordNotFound
          render json: { success: false, errors: ['Publicação não encontrada.'] }, status: :not_found
        end

        def create
          upload = ::GestorPosts::Upload.new(
            created_by: current_user.id,
            caption: params[:caption],
            platforms: Array(params[:platforms]),
            content_type: params[:content_type]
          )

          if params[:media].blank?
            return render json: { success: false, errors: ['Arquivo de mídia é obrigatório.'] }, status: :unprocessable_entity
          end

          upload.media.attach(params[:media])

          if upload.save
            ::GestorPosts::PublishJob.perform_later(upload.id, social_channel.class.name, social_channel.id)
            render json: { success: true, data: { id: upload.id, status: upload.status } }, status: :created
          else
            render json: { success: false, errors: upload.errors.full_messages }, status: :unprocessable_entity
          end
        end
      end
    end
  end
end
