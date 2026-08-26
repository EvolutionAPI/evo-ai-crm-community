class Webhooks::WhatsappController < ActionController::API
  include MetaTokenVerifyConcern

  def process_payload
    # Check if this is an Evolution Go webhook payload
    if evolution_go_payload?
      Rails.logger.info 'Evolution Go webhook detected, processing with Evolution Go handler'
      return process_evolution_go_payload
    end

    if inactive_whatsapp_number?
      Rails.logger.warn("Rejected webhook for inactive WhatsApp number: #{params[:phone_number]}")
      render json: { error: 'Inactive WhatsApp number' }, status: :unprocessable_entity
      return
    end

    perform_whatsapp_events_job
  end

  def process_evolution_go_payload
    Rails.logger.info "Evolution Go webhook received: #{params.slice(:event, :instanceId, :instanceToken)}"

    # Evolution Go webhook structure validation
    unless valid_evolution_go_payload?
      Rails.logger.warn 'Invalid Evolution Go webhook payload: missing required fields'
      render json: { error: 'Invalid Evolution Go webhook payload' }, status: :bad_request
      return
    end

    # Process Evolution Go webhook
    Webhooks::WhatsappEventsJob.perform_later(params.to_unsafe_hash.merge(evolution_go: true))
    head :ok
  end

  private

  def valid_evolution_go_payload?
    # Evolution Go webhook must have: event, data, instanceId, instanceToken
    params[:event].present? &&
      params[:data].present? &&
      params[:instanceId].present? &&
      params[:instanceToken].present?
  end

  def perform_whatsapp_events_job
    perform_sync if params[:awaitResponse].present?
    return if performed?

    Webhooks::WhatsappEventsJob.perform_later(params.to_unsafe_hash)
    head :ok
  end

  def perform_sync
    Webhooks::WhatsappEventsJob.perform_now(params.to_unsafe_hash)
  rescue Whatsapp::EvolutionHandlers::MessagesUpdate::MessageNotFoundError
    head :not_found
  end

  def valid_token?(token)
    if using_global_webhook?
      validate_global_token(token)
    else
      validate_phone_specific_token(token)
    end
  end

  def using_global_webhook?
    params[:phone_number].blank?
  end

  def validate_global_token(token)
    global_verify_token = GlobalConfig.get_value('WP_VERIFY_TOKEN')

    log_global_token_check(token, global_verify_token)

    return token == global_verify_token if global_verify_token.present?

    Rails.logger.warn 'No global WhatsApp webhook verify token configured'
    false
  end

  def validate_phone_specific_token(token)
    channel = find_whatsapp_channel_by_phone
    whatsapp_webhook_verify_token = extract_webhook_token(channel)

    log_phone_specific_token_check(token, whatsapp_webhook_verify_token)

    token == whatsapp_webhook_verify_token if whatsapp_webhook_verify_token.present?
  end

  def find_whatsapp_channel_by_phone
    Channel::Whatsapp.find_by(phone_number: params[:phone_number])
  end

  def extract_webhook_token(channel)
    return nil if channel.blank?

    channel.provider_config&.dig('webhook_verify_token')
  end

  def log_global_token_check(token, global_verify_token)
    token_status = token.present? ? '[PRESENT]' : '[MISSING]'
    global_status = global_verify_token.present? ? '[PRESENT]' : '[MISSING]'

    Rails.logger.info 'Global WhatsApp webhook verify token check: ' \
                      "provided=#{token_status}, global=#{global_status}"
  end

  def log_phone_specific_token_check(token, whatsapp_webhook_verify_token)
    token_status = token.present? ? '[PRESENT]' : '[MISSING]'
    channel_status = whatsapp_webhook_verify_token.present? ? '[PRESENT]' : '[MISSING]'

    Rails.logger.info 'Phone-specific WhatsApp webhook verify token check ' \
                      "for #{params[:phone_number]}: provided=#{token_status}, " \
                      "channel=#{channel_status}"
  end

  def inactive_whatsapp_number?
    phone_number = params[:phone_number]
    return false if phone_number.blank?

    inactive_numbers = GlobalConfig.get_value('INACTIVE_WHATSAPP_NUMBERS').to_s
    return false if inactive_numbers.blank?

    inactive_numbers_array = inactive_numbers.split(',').map(&:strip)
    inactive_numbers_array.include?(phone_number)
  end

  def evolution_go_payload?
    # Evolution Go webhooks have instanceId and instanceToken at root level
    params[:instanceId].present? && params[:instanceToken].present? && params[:event].present?
  end
end
