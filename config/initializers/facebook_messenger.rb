# ref: https://github.com/jgorset/facebook-messenger#make-a-configuration-provider
class EvolutionFbProvider < Facebook::Messenger::Configuration::Providers::Base
  # The gem only checks the truthiness of the return value, so this has to compare
  # the tokens itself. An unconfigured FB_VERIFY_TOKEN must refuse, never verify.
  def valid_verify_token?(verify_token)
    configured_token = GlobalConfigService.load('FB_VERIFY_TOKEN', '')

    configured_token.present? && verify_token == configured_token
  end

  def app_secret_for(_page_id)
    GlobalConfigService.load('FB_APP_SECRET', '')
  end

  def access_token_for(page_id)
    Channel::FacebookPage.where(page_id: page_id).last.page_access_token
  end

  private

  def bot
    Evolution::Bot
  end
end

Rails.application.reloader.to_prepare do
  Facebook::Messenger.configure do |config|
    config.provider = EvolutionFbProvider.new
  end

  # Monkey-patch the facebook-messenger gem to route outbound Bot.deliver
  # calls through the Evolution Hub when the feature is enabled.
  #
  # The gem hard-codes `https://graph.facebook.com` in Facebook::Messenger::Bot.
  # We patch the constant to honour MetaBaseUrl.for(:facebook) — which is what
  # MetaBaseUrl returns when Hub is OFF anyway, so the patch is safe at all
  # times. The reloader runs after MetaBaseUrl is loaded and after the DB is
  # ready, so GlobalConfigService.load works.
  if defined?(Facebook::Messenger::Bot) && defined?(MetaBaseUrl)
    Facebook::Messenger::Bot.singleton_class.class_eval do
      define_method(:base_uri) do
        # Returns the URL WITHOUT trailing /vXX.0 — the gem appends "/me/messages"
        # or "/{page_id}/messages" itself. MetaBaseUrl returns ".../v23.0".
        MetaBaseUrl.for(:facebook)
      end
    end
  end

  Facebook::Messenger::Bot.on :message do |message|
    Webhooks::FacebookEventsJob.perform_later(message.to_json)
  end

  Facebook::Messenger::Bot.on :delivery do |delivery|
    Rails.logger.info "Recieved delivery status #{delivery.to_json}"
    Webhooks::FacebookDeliveryJob.perform_later(delivery.to_json)
  end

  Facebook::Messenger::Bot.on :read do |read|
    Rails.logger.info "Recieved read status  #{read.to_json}"
    Webhooks::FacebookDeliveryJob.perform_later(read.to_json)
  end

  Facebook::Messenger::Bot.on :message_echo do |message|
    Webhooks::FacebookEventsJob.perform_later(message.to_json)
  end
end
