module Api
  module V1
    module GestorPosts
      class CarouselUploadsController < BaseController
        before_action :require_social_channel!, only: [:create]

        def create
          batch = ::CarouselUploadBatch.new(
            created_by: current_user.id,
            caption: params[:caption],
            platforms: Array(params[:platforms]),
            total_cards: params[:total_cards],
            channel_type: social_channel.class.name,
            channel_id: social_channel.id.to_s
          )

          if batch.save
            render json: { success: true, data: { id: batch.id, status: batch.status } }, status: :created
          else
            render json: { success: false, errors: batch.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def show
          batch = ::CarouselUploadBatch.find(params[:id])
          render json: { success: true, data: batch_json(batch) }
        rescue ActiveRecord::RecordNotFound
          render json: { success: false, errors: ['Lote não encontrado.'] }, status: :not_found
        end

        def add_card
          batch = ::CarouselUploadBatch.find(params[:id])

          if params[:media].blank?
            return render json: { success: false, errors: ['Arquivo de mídia é obrigatório.'] }, status: :unprocessable_entity
          end

          unless batch.status == 'collecting'
            return render json: { success: false, errors: ['Lote não está mais coletando cards.'] }, status: :unprocessable_entity
          end

          blob = ActiveStorage::Blob.create_and_upload!(
            io: params[:media].tempfile,
            filename: params[:media].original_filename,
            content_type: params[:media].content_type
          )
          image_url = BlobUrlOptions.outbound_media_url(blob, expires_in: 30.minutes)
          channel = batch.channel_type.constantize.find(batch.channel_id)

          batch.platforms.each do |platform|
            container_id = create_card(platform, channel, image_url)
            batch.append_container!(platform, container_id)
          end

          batch.reload
          if batch.complete?
            ::GestorPosts::CarouselPublishJob.perform_later(batch.id)
          end

          render json: { success: true, data: batch_json(batch) }
        rescue ActiveRecord::RecordNotFound
          render json: { success: false, errors: ['Lote ou canal não encontrado.'] }, status: :not_found
        rescue Instagram::PublishService::Error, Facebook::PublishService::Error => e
          render json: { success: false, errors: [e.message] }, status: :unprocessable_entity
        end

        private

        def create_card(platform, channel, image_url)
          case platform
          when 'instagram' then Instagram::PublishService.new(channel: channel).create_carousel_card(image_url: image_url)
          when 'facebook' then Facebook::PublishService.new(channel: channel).create_carousel_card(image_url: image_url)
          end
        end

        def batch_json(batch)
          batch.as_json(only: %i[id caption platforms total_cards status error_message external_post_ids created_at])
               .merge(cards_collected: batch.platforms.index_with { |p| batch.cards_for(p).size })
        end
      end
    end
  end
end
