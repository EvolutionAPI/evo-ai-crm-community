module ScheduledPosts
  # Publica de verdade um ScheduledPost vencido, no mesmo molde síncrono do
  # ScheduledActions::ExecutorService: marca executing -> chama os serviços
  # de publish reais -> completed ou failed (com retry_count).
  class ExecutorService
    attr_reader :scheduled_post

    def initialize(scheduled_post)
      @scheduled_post = scheduled_post
    end

    def execute
      return false unless scheduled_post.scheduled?
      return false if scheduled_post.scheduled_for > Time.current

      scheduled_post.mark_as_executing!

      channel = scheduled_post.channel_type.constantize.find_by(id: scheduled_post.channel_id)
      unless channel
        scheduled_post.mark_as_failed!('Conta/canal não encontrado.')
        return false
      end

      errors = []
      scheduled_post.platforms.each do |platform|
        publish_to(platform, channel)
      rescue StandardError => e
        Rails.logger.error("ScheduledPosts::ExecutorService: #{platform} error for post #{scheduled_post.id}: #{e.message}")
        errors << "#{platform}: #{e.message}"
      end

      if errors.any?
        scheduled_post.mark_as_failed!(errors.join('; '))
        false
      else
        scheduled_post.mark_as_completed!
        true
      end
    end

    private

    def publish_to(platform, channel)
      case platform
      when 'instagram'
        Instagram::PublishService.new(channel: channel, upload: scheduled_post).publish!
      when 'facebook'
        Facebook::PublishService.new(channel: channel, upload: scheduled_post).publish!
      end
    end
  end
end
