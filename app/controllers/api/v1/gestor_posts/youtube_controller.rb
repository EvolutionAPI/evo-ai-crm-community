module Api
  module V1
    module GestorPosts
      class YoutubeController < BaseController
        def connected
          render json: { success: true, data: { connected: Google::WorkspaceTokenService.new.connected? } }
        end

        def create
          if params[:video].blank?
            return render json: { success: false, errors: ['Arquivo de vídeo é obrigatório.'] }, status: :unprocessable_entity
          end

          upload = ::YoutubeUpload.new(
            created_by: current_user.id,
            title: params[:title],
            description: params[:description],
            privacy_status: params[:privacy_status].presence || 'unlisted'
          )

          if upload.save
            upload.video.attach(params[:video])
            ::GestorPosts::YoutubeUploadJob.perform_later(upload.id)
            render json: { success: true, data: upload_json(upload) }, status: :created
          else
            render json: { success: false, errors: upload.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def show
          upload = ::YoutubeUpload.find(params[:id])
          render json: { success: true, data: upload_json(upload) }
        rescue ActiveRecord::RecordNotFound
          render json: { success: false, errors: ['Upload não encontrado.'] }, status: :not_found
        end

        private

        def upload_json(upload)
          upload.as_json(only: %i[id title description privacy_status status error_message external_video_id created_at])
        end
      end
    end
  end
end
