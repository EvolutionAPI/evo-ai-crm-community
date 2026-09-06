module Api
  module V1
    module GestorPosts
      class WhatsappStatusController < BaseController
        # Lista os canais de WhatsApp cujo provider suporta Status (hoje só
        # a Evolution API tem esse método implementado).
        def channels
          options = ::Channel::Whatsapp.all.select { |c| c.provider_service.respond_to?(:send_status) }
                                        .map { |c| { channel_id: c.id, name: c.inbox&.name || c.phone_number } }
          render json: { success: true, data: options }
        end

        def create
          channel = ::Channel::Whatsapp.find(params[:channel_id])
          unless channel.provider_service.respond_to?(:send_status)
            return render json: { success: false, errors: ['Este provedor de WhatsApp não suporta Status.'] }, status: :unprocessable_entity
          end

          type = params[:type].to_s
          content =
            if type == 'text'
              params[:content]
            elsif params[:media].present?
              blob = ActiveStorage::Blob.create_and_upload!(
                io: params[:media].tempfile,
                filename: params[:media].original_filename,
                content_type: params[:media].content_type
              )
              BlobUrlOptions.outbound_media_url(blob, expires_in: 30.minutes)
            end

          if content.blank?
            return render json: { success: false, errors: ['Conteúdo do status é obrigatório.'] }, status: :unprocessable_entity
          end

          result = channel.provider_service.send_status(type: type, content: content, caption: params[:caption].presence)

          if result
            render json: { success: true, data: { id: result } }, status: :created
          else
            render json: { success: false, errors: ['Falha ao publicar o status no WhatsApp.'] }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordNotFound
          render json: { success: false, errors: ['Canal de WhatsApp não encontrado.'] }, status: :not_found
        rescue ArgumentError => e
          render json: { success: false, errors: [e.message] }, status: :unprocessable_entity
        end
      end
    end
  end
end
