class Api::V1::Evolution::AuthorizationsController < Api::V1::BaseController
  def create
    Rails.logger.info "Evolution API connection verification called with params: #{params.inspect}"

    # Parâmetros vêm dentro de authorization
    auth_params = params[:authorization] || params

    api_url = auth_params[:api_url].presence || GlobalConfigService.load('EVOLUTION_API_URL', '').to_s.strip
    admin_token = auth_params[:admin_token].presence || GlobalConfigService.load('EVOLUTION_ADMIN_SECRET', '').to_s.strip
    instance_name = auth_params[:instance_name]
    phone_number = auth_params[:phone_number]

    missing_params = []
    missing_params << 'api_url' if api_url.blank?
    missing_params << 'admin_token' if admin_token.blank?
    missing_params << 'instance_name' if instance_name.blank?
    missing_params << 'phone_number' if phone_number.blank?

    if missing_params.any?
      Rails.logger.warn "Evolution API: Missing parameters: #{missing_params.join(', ')}. Params: #{params.inspect}"
      return error_response(
        ApiErrorCodes::MISSING_REQUIRED_FIELD,
        "Missing required parameters: #{missing_params.join(', ')}",
        status: :bad_request
      )
    end

    begin
      # First, check if Evolution API is running by hitting the root endpoint
      evolution_status = check_server_status(api_url)

      # Check if instance already exists, delete if it does
      check_and_delete_existing_instance(api_url, admin_token, instance_name)

      # Create new instance
      instance_data = create_instance(api_url, admin_token, instance_name, phone_number, auth_params)

      # Apply proxy settings if provided
      if auth_params[:proxy_settings].present?
        Rails.logger.info "Evolution API: Applying proxy settings for instance #{instance_name}"
        apply_proxy_settings(api_url, admin_token, instance_name, auth_params[:proxy_settings])
      end

      # Apply instance settings if provided
      if auth_params[:instance_settings].present?
        Rails.logger.info "Evolution API: Applying instance settings for instance #{instance_name}"
        apply_instance_settings(api_url, admin_token, instance_name, auth_params[:instance_settings])
      end

      # Get QR code for the new instance
      # qrcode_data = get_qrcode(api_url, instance_data['hash'], instance_name)

      success_response(
        data: {
          evolution_info: {
            version: evolution_status['version'],
            client_name: evolution_status['clientName'],
            whatsapp_version: evolution_status['whatsappWebVersion']
          },
          instance: instance_data
          # qrcode: qrcode_data
        },
        message: 'Instance created successfully'
      )
    rescue StandardError => e
      Rails.logger.error "Evolution API connection error: #{e.message}"
      error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
    end
  end

  private

  def check_server_status(api_url)
    instance_url = "#{api_url.chomp('/')}/"
    Rails.logger.info "Evolution API: Checking server at #{instance_url}"

    uri = URI.parse(instance_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 10

    request = Net::HTTP::Get.new(uri)
    request['Content-Type'] = 'application/json'

    Rails.logger.info "Evolution API: Request headers: #{request.to_hash}"

    response = http.request(request)
    Rails.logger.info "Evolution API: Server response code: #{response.code}"
    Rails.logger.info "Evolution API: Server response body: #{response.body}"

    raise "Server verification failed. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Server JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API server endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: Server connection error: #{e.class} - #{e.message}"
    raise "Failed to verify instance: #{e.message}"
  end

  def create_instance(api_url, admin_token, instance_name, phone_number, auth_params)
    create_url = "#{api_url.chomp('/')}/instance/create"
    Rails.logger.info "Evolution API: Creating instance at #{create_url}"

    # Clean phone number (remove +, spaces, -)
    clean_number = phone_number.gsub(/[\+\s\-]/, '')

    # Get webhook URL (following Evolution pattern)
    webhook_url_value = webhook_url

    # Webhook events - fixed list as per Evolution v2 specification
    webhook_events = [
      'CONNECTION_UPDATE',     # Connection status changes
      'CONTACTS_SET',          # Historical contacts sync (initial)
      'CONTACTS_UPDATE',       # Contact updates
      'CONTACTS_UPSERT',       # Contact create/update
      'LABELS_ASSOCIATION',    # Label associations
      'LABELS_EDIT',           # Label edits
      'LOGOUT_INSTANCE',       # Instance logout events
      'MESSAGES_DELETE',       # Message deletions
      'MESSAGES_UPDATE',       # Message updates (read status, etc)
      'MESSAGES_UPSERT',       # New incoming messages
      'SEND_MESSAGE'           # Sent message events
    ]

    Rails.logger.info "Evolution v2: Configured webhook events: #{webhook_events.join(', ')}"

    request_body = {
      instanceName: instance_name,
      number: clean_number,
      integration: 'WHATSAPP-BAILEYS',
      qrcode: false,
      webhook: {
        url: webhook_url_value,
        byEvents: false,
        base64: true,
        events: webhook_events
      }
    }

    uri = URI.parse(create_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = admin_token
    request['Content-Type'] = 'application/json'
    request.body = request_body.to_json

    Rails.logger.info "Evolution API: Create instance request headers: #{request.to_hash}"
    Rails.logger.info "Evolution API: Create instance request body: #{request.body}"

    response = http.request(request)
    Rails.logger.info "Evolution API: Create instance response code: #{response.code}"
    Rails.logger.info "Evolution API: Create instance response body: #{response.body}"

    raise "Failed to create instance. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Create instance JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API create instance endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: Create instance connection error: #{e.class} - #{e.message}"
    raise "Failed to create instance: #{e.message}"
  end

  def check_and_delete_existing_instance(api_url, admin_token, instance_name)
    # Try to fetch existing instances

    fetch_instances(api_url, admin_token, instance_name)
    # If we get here, instance exists, so delete it
    Rails.logger.info "Evolution API: Instance #{instance_name} exists, deleting it"
    delete_instance(api_url, admin_token, instance_name)
    Rails.logger.info "Evolution API: Instance #{instance_name} deleted successfully"

    # Wait a bit for Evolution API to process the deletion
    Rails.logger.info 'Evolution API: Waiting 2 seconds for deletion to be processed...'
    sleep(2)

    # Verify the instance was actually deleted
    begin
      fetch_instances(api_url, admin_token, instance_name)
      # If we get here, instance still exists after deletion
      Rails.logger.error "Evolution API: Instance #{instance_name} still exists after deletion attempt"
      raise 'Instance deletion failed - instance still exists'
    rescue StandardError => e
      # If 404 or error, instance is gone - good!
      Rails.logger.info "Evolution API: Verified instance #{instance_name} was deleted (#{e.message})"
    end

  rescue StandardError => e
    # If 404 or any error, instance doesn't exist, which is fine
    Rails.logger.info "Evolution API: Instance #{instance_name} doesn't exist (#{e.message}), proceeding with creation"
  end

  def fetch_instances(api_url, admin_token, instance_name)
    fetch_url = "#{api_url.chomp('/')}/instance/fetchInstances?instanceName=#{instance_name}"
    Rails.logger.info "Evolution API: Fetching instances at #{fetch_url}"

    uri = URI.parse(fetch_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 10

    request = Net::HTTP::Get.new(uri)
    request['apikey'] = admin_token
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Evolution API: Fetch instances response code: #{response.code}"
    Rails.logger.info "Evolution API: Fetch instances response body: #{response.body}"

    # If 404, instance doesn't exist
    raise 'Instance not found' if response.code == '404'

    raise "Failed to fetch instances. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Fetch instances JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API fetchInstances endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: Fetch instances connection error: #{e.class} - #{e.message}"
    raise e.message
  end

  def delete_instance(api_url, admin_token, instance_name)
    delete_url = "#{api_url.chomp('/')}/instance/delete/#{instance_name}"
    Rails.logger.info "Evolution API: Deleting instance at #{delete_url}"

    uri = URI.parse(delete_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Delete.new(uri)
    request['apikey'] = admin_token
    request['Content-Type'] = 'application/json'

    response = http.request(request)

    Rails.logger.info "Evolution API: Delete instance response code: #{response.code}"
    Rails.logger.info "Evolution API: Delete instance response body: #{response.body}"

    raise "Failed to delete instance. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Delete instance JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API delete endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: Delete instance connection error: #{e.class} - #{e.message}"
    raise "Failed to delete instance: #{e.message}"
  end

  def get_qrcode(api_url, api_hash, instance_name)
    qrcode_url = "#{api_url.chomp('/')}/instance/connect/#{instance_name}"
    Rails.logger.info "Evolution API: Getting QR code at #{qrcode_url}"

    uri = URI.parse(qrcode_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Get.new(uri)
    request['apikey'] = api_hash
    request['Content-Type'] = 'application/json'

    Rails.logger.info "Evolution API: QR code request headers: #{request.to_hash}"

    response = http.request(request)
    Rails.logger.info "Evolution API: QR code response code: #{response.code}"
    Rails.logger.info "Evolution API: QR code response body: #{response.body}"

    raise "Failed to get QR code. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: QR code JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API QR code endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: QR code connection error: #{e.class} - #{e.message}"
    raise "Failed to get QR code: #{e.message}"
  end

  def webhook_url
    api_url = ENV['BACKEND_URL'].to_s.strip
    raise 'BACKEND_URL is not configured (required to register Evolution webhook callback)' if api_url.empty?

    "#{api_url.chomp('/')}/webhooks/whatsapp/evolution"
  end

  def apply_proxy_settings(api_url, admin_token, instance_name, proxy_settings)
    return unless proxy_settings['enabled']

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
        'apikey' => admin_token
      },
      timeout: 30
    )

    return if response.success?

    Rails.logger.warn "[EVOLUTION] Proxy configuration failed: #{response.body}"
  end

  def apply_instance_settings(api_url, admin_token, instance_name, instance_settings)
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
        'apikey' => admin_token
      },
      timeout: 30
    )

    return if response.success?

    Rails.logger.warn "[EVOLUTION] Instance settings configuration failed: #{response.body}"
  end
end
