# frozen_string_literal: true

class WhatsappSyncInitiatorJob < ApplicationJob
  queue_as :default

  def perform(inbox_id)
    inbox = Inbox.find(inbox_id)
    channel = inbox.channel

    Rails.logger.info "[WHATSAPP] Starting sync initiation for #{channel.provider} channel #{channel.phone_number}"

    case channel.provider
    when 'whatsapp_cloud'
      handle_whatsapp_cloud_sync(channel)
    when 'evolution'
      handle_evolution_setup(channel)
    else
      Rails.logger.warn "[WHATSAPP] Unsupported provider for sync: #{channel.provider}"
    end
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP] Sync initiation failed for inbox #{inbox_id}: #{e.message}"
    raise e
  end

  private

  def handle_whatsapp_cloud_sync(channel)
    setup_actions = extract_setup_actions(channel)

    Rails.logger.info "[WHATSAPP] Starting WhatsApp Cloud sync with actions: #{setup_actions}"

    # Skip phone number registration for business app onboarding
    register_phone_number(channel) unless skip_phone_registration?(channel)

    # Configure webhook subscription
    configure_webhook_subscription(channel)

    # Request sync if enabled
    sync_contacts(channel) if setup_actions.include?('sync_contacts')

    request_conversation_history_sync(channel) if setup_actions.include?('sync_conversations')

    Rails.logger.info '[WHATSAPP] WhatsApp Cloud sync initiation completed'
  end

  def handle_evolution_setup(channel)
    Rails.logger.info "[WHATSAPP] Starting Evolution API setup for channel #{channel.phone_number}"

    # Create Evolution instance
    create_evolution_instance(channel)

    # Apply configurations
    apply_evolution_configurations(channel)

    Rails.logger.info "[WHATSAPP] Evolution API setup completed for channel #{channel.phone_number}"
  end

  def create_evolution_instance(channel)
    api_url = channel.provider_config['api_url']
    admin_token = channel.provider_config['admin_token']
    instance_name = channel.provider_config['instance_name']
    phone_number = channel.phone_number

    create_url = "#{api_url.chomp('/')}/instance/create"
    Rails.logger.info "[EVOLUTION] Creating instance at #{create_url}"

    # Clean phone number (remove +, spaces, -)
    clean_number = phone_number.gsub(/[\+\s\-]/, '')

    backend_url = ENV['BACKEND_URL'].to_s.strip
    raise 'BACKEND_URL is not configured (required to register Evolution webhook callback)' if backend_url.empty?

    webhook_url_value = "#{backend_url.chomp('/')}/webhooks/whatsapp/evolution"

    request_body = {
      instanceName: instance_name,
      number: clean_number,
      integration: 'WHATSAPP-BAILEYS',
      qrcode: false,
      webhook: {
        url: webhook_url_value,
        byEvents: false,
        base64: true,
        events: webhook_events_for_sync
      }
    }

    Rails.logger.info "[EVOLUTION] Instance creation request: #{request_body.except(:webhook).inspect}"

    response = HTTParty.post(
      create_url,
      body: request_body.to_json,
      headers: {
        'Content-Type' => 'application/json',
        'apikey' => admin_token
      },
      timeout: 30
    )

    if response.success?
      instance_data = response.parsed_response
      Rails.logger.info "[EVOLUTION] Instance created successfully: #{instance_data['instance']['instanceName']}"

      # Store api_hash in provider_config for future use
      channel.update!(
        provider_config: channel.provider_config.merge(
          'api_hash' => instance_data['hash'],
          'instance_id' => instance_data['instance']['instanceId']
        )
      )

      instance_data
    else
      error_msg = "Evolution instance creation failed: #{response.code} - #{response.body}"
      Rails.logger.error "[EVOLUTION] #{error_msg}"
      raise StandardError, error_msg
    end
  end

  def apply_evolution_configurations(channel)
    api_url = channel.provider_config['api_url']
    api_hash = channel.provider_config['api_hash']
    instance_name = channel.provider_config['instance_name']
    proxy_settings = channel.provider_config['proxy_settings'] || {}
    instance_settings = channel.provider_config['instance_settings'] || {}

    # Apply proxy settings if enabled
    configure_evolution_proxy(api_url, api_hash, instance_name, proxy_settings) if proxy_settings['enabled']

    # Apply instance settings
    configure_evolution_instance_settings(api_url, api_hash, instance_name, instance_settings)
  end

  def configure_evolution_proxy(api_url, api_hash, instance_name, proxy_settings)
    proxy_url = "#{api_url.chomp('/')}/proxy/set/#{instance_name}"

    proxy_body = {
      proxy: {
        host: proxy_settings['host'],
        port: proxy_settings['port'].to_i,
        protocol: proxy_settings['protocol'],
        username: proxy_settings['username'],
        password: proxy_settings['password']
      }
    }

    Rails.logger.info "[EVOLUTION] Setting proxy configuration for #{instance_name}"

    response = HTTParty.post(
      proxy_url,
      body: proxy_body.to_json,
      headers: {
        'Content-Type' => 'application/json',
        'apikey' => api_hash
      },
      timeout: 30
    )

    return if response.success?

    Rails.logger.warn "[EVOLUTION] Proxy configuration failed: #{response.body}"
  end

  def configure_evolution_instance_settings(api_url, api_hash, instance_name, instance_settings)
    settings_url = "#{api_url.chomp('/')}/settings/set/#{instance_name}"

    settings_body = {
      rejectCall: instance_settings['rejectCall'],
      msgCall: instance_settings['msgCall'],
      groupsIgnore: instance_settings['groupsIgnore'],
      alwaysOnline: instance_settings['alwaysOnline'],
      readMessages: instance_settings['readMessages'],
      readStatus: instance_settings['readStatus']
    }

    Rails.logger.info "[EVOLUTION] Setting instance configuration for #{instance_name}"

    response = HTTParty.post(
      settings_url,
      body: settings_body.to_json,
      headers: {
        'Content-Type' => 'application/json',
        'apikey' => api_hash
      },
      timeout: 30
    )

    return if response.success?

    Rails.logger.warn "[EVOLUTION] Instance settings configuration failed: #{response.body}"
  end

  def webhook_events_for_sync
    events = %w[
      MESSAGES_UPSERT
      MESSAGES_UPDATE
      MESSAGES_DELETE
    ]

    # Add sync events if sync is enabled
    events += %w[
      MESSAGES_SET
      CONTACTS_UPSERT
      CONTACTS_UPDATE
    ]

    events
  end

  # WhatsApp Cloud methods (unchanged)
  def extract_setup_actions(channel)
    provider_config = channel.provider_config || {}
    setup_actions_config = provider_config['setup_actions'] || {}

    setup_actions = parse_setup_actions_config(setup_actions_config)
    setup_actions = apply_default_actions(setup_actions, channel) if setup_actions.empty?

    Rails.logger.info "[WHATSAPP] Extracted setup actions: #{setup_actions.inspect} (is_business_app: #{skip_phone_registration?(channel)})"
    setup_actions
  end

  def parse_setup_actions_config(setup_actions_config)
    return setup_actions_config if setup_actions_config.is_a?(Array)
    return [] unless setup_actions_config.is_a?(Hash)

    # Convert hash flags to array format
    actions = []
    if setup_actions_config['enable_sync_features']
      actions << 'sync_contacts'
      actions << 'sync_conversations'
    end
    actions
  end

  def apply_default_actions(setup_actions, channel)
    # Default actions for non-business app onboarding
    return setup_actions unless setup_actions.empty?
    return setup_actions if skip_phone_registration?(channel)

    %w[sync_contacts sync_conversations]
  end

  def skip_phone_registration?(channel)
    provider_config = channel.provider_config || {}
    # Check both old and new flag locations for backward compatibility
    provider_config['is_business_app_onboarding'] == true ||
      provider_config.dig('setup_actions', 'register_phone_number') == false
  end

  def register_phone_number(channel)
    phone_number_id = channel.provider_config['phone_number_id']
    access_token = channel.provider_config['business_account_id']

    Rails.logger.info "[WHATSAPP] Registering phone number for channel #{channel.phone_number}"

    response = HTTParty.post(
      "https://graph.facebook.com/v23.0/#{phone_number_id}/register",
      headers: {
        'Authorization' => "Bearer #{access_token}",
        'Content-Type' => 'application/json'
      },
      body: {
        messaging_product: 'whatsapp',
        pin: '123456' # This should be configurable
      }.to_json,
      timeout: 30
    )

    if response.success?
      Rails.logger.info '[WHATSAPP] Phone number registration successful'
    else
      Rails.logger.warn "[WHATSAPP] Phone number registration failed: #{response.body}"
    end
  end

  def configure_webhook_subscription(channel)
    business_account_id = channel.provider_config['business_account_id']
    access_token = channel.provider_config['access_token']
    webhook_fields = %w[messages smb_app_state_sync smb_message_echoes]

    Rails.logger.info "[WHATSAPP] Configuring webhook subscription with fields: #{webhook_fields}"

    response = HTTParty.post(
      "https://graph.facebook.com/v23.0/#{business_account_id}/subscribed_apps",
      headers: {
        'Authorization' => "Bearer #{access_token}",
        'Content-Type' => 'application/json'
      },
      body: {
        subscribed_fields: webhook_fields
      }.to_json,
      timeout: 30
    )

    if response.success?
      Rails.logger.info '[WHATSAPP] Webhook subscription configured successfully'
    else
      Rails.logger.warn "[WHATSAPP] Webhook subscription failed: #{response.body}"
    end
  end

  def sync_contacts(channel)
    phone_number_id = channel.provider_config['phone_number_id']
    access_token = channel.provider_config['access_token']

    Rails.logger.info "[WHATSAPP] Requesting contact sync for channel #{channel.phone_number}"

    response = HTTParty.post(
      "https://graph.facebook.com/v23.0/#{phone_number_id}/smb_app_data",
      headers: {
        'Authorization' => "Bearer #{access_token}",
        'Content-Type' => 'application/json'
      },
      body: {
        messaging_product: 'whatsapp',
        sync_type: 'smb_app_state_sync'
      }.to_json,
      timeout: 30
    )

    if response.success?
      Rails.logger.info '[WHATSAPP] Contact sync request sent successfully'
    else
      Rails.logger.warn "[WHATSAPP] Contact sync request failed: #{response.body}"
    end
  end

  def request_conversation_history_sync(channel)
    phone_number_id = channel.provider_config['phone_number_id']
    access_token = channel.provider_config['access_token']

    Rails.logger.info "[WHATSAPP] Requesting conversation history sync for channel #{channel.phone_number}"

    response = HTTParty.post(
      "https://graph.facebook.com/v23.0/#{phone_number_id}/smb_app_data",
      headers: {
        'Authorization' => "Bearer #{access_token}",
        'Content-Type' => 'application/json'
      },
      body: {
        messaging_product: 'whatsapp',
        sync_type: 'history'
      }.to_json,
      timeout: 30
    )

    if response.success?
      Rails.logger.info '[WHATSAPP] Conversation history sync request sent successfully'
    else
      Rails.logger.warn "[WHATSAPP] Conversation history sync request failed: #{response.body}"
    end
  end
end
