class Webhooks::InstagramController < ActionController::API
  include MetaTokenVerifyConcern

  def events
    Rails.logger.info('Instagram webhook received events')
    Rails.logger.info("Instagram webhook params object: #{params['object'].inspect}")
    Rails.logger.info("Instagram webhook entry count: #{params[:entry]&.length || 0}")

    if params['object'].casecmp('instagram').zero?
      # Log full entry structure for debugging
      params[:entry]&.each_with_index do |entry, idx|
        Rails.logger.info("Instagram webhook entry[#{idx}]: id=#{entry[:id]}, time=#{entry[:time]}")
        Rails.logger.info("Instagram webhook entry[#{idx}] messaging count: #{entry[:messaging]&.length || 0}")
        entry[:messaging]&.each_with_index do |msg, msg_idx|
          Rails.logger.info("Instagram webhook entry[#{idx}] messaging[#{msg_idx}] keys: #{msg.keys.inspect}")
          Rails.logger.info("Instagram webhook entry[#{idx}] messaging[#{msg_idx}] has sender: #{msg[:sender].present?}, has recipient: #{msg[:recipient].present?}, has message: #{msg[:message].present?}")

          # Log sender and recipient IDs for verification
          if msg[:sender].present?
            Rails.logger.info("Instagram webhook entry[#{idx}] messaging[#{msg_idx}] SENDER ID: #{msg[:sender][:id]}")
          end
          if msg[:recipient].present?
            Rails.logger.info("Instagram webhook entry[#{idx}] messaging[#{msg_idx}] RECIPIENT ID: #{msg[:recipient][:id]}")
          end
        end
      end

      ::Webhooks::InstagramEventsJob.perform_later(params.to_unsafe_hash[:entry])
      render json: :ok
    else
      Rails.logger.warn("Message is not received from the instagram webhook event: #{params['object']}")
      head :unprocessable_entity
    end
  end

  private

  def valid_token?(token)
    # Both configs default to '', so a blank token would match an unconfigured channel.
    return false if token.blank?

    # IG_VERIFY_TOKEN is the Instagram channel via a Facebook page;
    # INSTAGRAM_VERIFY_TOKEN is the channel via direct Instagram login.
    token == GlobalConfigService.load('IG_VERIFY_TOKEN', '') ||
      token == GlobalConfigService.load('INSTAGRAM_VERIFY_TOKEN', '')
  end
end
