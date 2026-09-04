module GestorPosts
  # Publica um GestorPosts::Upload nas plataformas selecionadas (fan-out
  # instagram/facebook). Roda em background porque publicação de vídeo pode
  # ser lenta e um upload pode ter várias plataformas de uma vez.
  class PublishJob < ApplicationJob
    queue_as :default

    def perform(upload_id, channel_type, channel_id)
      upload = GestorPosts::Upload.find_by(id: upload_id)
      return unless upload

      channel = channel_type.constantize.find_by(id: channel_id)
      unless channel
        upload.mark_failed!('Conta/canal não encontrado.')
        return
      end

      upload.mark_publishing!
      errors = []

      upload.platforms.each do |platform|
        publish_to(platform, channel, upload)
      rescue StandardError => e
        Rails.logger.error("GestorPosts::PublishJob: #{platform} error for upload #{upload.id}: #{e.message}")
        errors << "#{platform}: #{e.message}"
      end

      if errors.any?
        upload.mark_failed!(errors.join('; '))
      else
        upload.mark_published!
      end
    end

    private

    def publish_to(platform, channel, upload)
      case platform
      when 'instagram'
        Instagram::PublishService.new(channel: channel, upload: upload).publish!
      when 'facebook'
        Facebook::PublishService.new(channel: channel, upload: upload).publish!
      end
    end
  end
end
