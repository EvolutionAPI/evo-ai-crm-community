module GestorPosts
  # Une os cards coletados de um CarouselUploadBatch e publica de verdade nas
  # plataformas selecionadas, assim que a última chamada de add_card completa
  # o lote (todas as plataformas com total_cards containers prontos).
  class CarouselPublishJob < ApplicationJob
    queue_as :default

    def perform(batch_id)
      batch = CarouselUploadBatch.find_by(id: batch_id)
      return unless batch
      return unless batch.complete?

      channel = batch.channel_type.constantize.find_by(id: batch.channel_id)
      unless channel
        batch.mark_failed!('Conta/canal não encontrado.')
        return
      end

      batch.mark_publishing!
      errors = []

      batch.platforms.each do |platform|
        publish_to(platform, channel, batch)
      rescue StandardError => e
        Rails.logger.error("GestorPosts::CarouselPublishJob: #{platform} error for batch #{batch.id}: #{e.message}")
        errors << "#{platform}: #{e.message}"
      end

      if errors.any?
        batch.mark_failed!(errors.join('; '))
      else
        batch.mark_published!
      end
    end

    private

    def publish_to(platform, channel, batch)
      case platform
      when 'instagram'
        id = Instagram::PublishService.new(channel: channel).publish_carousel!(
          container_ids: batch.cards_for('instagram'), caption: batch.caption
        )
        batch.mark_platform_published!('instagram', id)
      when 'facebook'
        id = Facebook::PublishService.new(channel: channel).publish_carousel!(
          photo_ids: batch.cards_for('facebook'), caption: batch.caption
        )
        batch.mark_platform_published!('facebook', id)
      end
    end
  end
end
