class Api::V1::EvolutionGo::AuthorizationsController < Api::V1::BaseController
  include EvolutionGoConcern

  require_permissions({
    create: 'inboxes.create',
    connect: 'inboxes.update',
    qrcode: 'inboxes.read',
    fetch: 'inboxes.read',
    logout: 'inboxes.update',
    delete_instance: 'inboxes.delete'
  })

  before_action :set_instance_params, only: [:create, :connect, :qrcode, :fetch, :logout, :delete_instance]

  # CREATE INSTANCE - POST /instance/create
  def create
    Rails.logger.info "Evolution Go API: Creating instance with params: #{params.inspect}"

    # Extract auth_params for instance settings
    auth_params = params[:authorization] || params
    mode = auth_params[:mode].to_s.presence || 'create'

    unless %w[test create].include?(mode)
      return render json: {
        error: "Invalid mode: #{mode}. Expected 'test' or 'create'"
      }, status: :bad_request
    end

    # Parâmetros básicos obrigatórios
    missing_params = []
    missing_params << 'api_url' if @api_url.blank?
    missing_params << 'admin_token' if @admin_token.blank?
    missing_params << 'instance_name' if @instance_name.blank?

    if missing_params.any?
      Rails.logger.warn "Evolution Go API: Missing parameters: #{missing_params.join(', ')}. Params: #{params.inspect}"
      return render json: {
        error: "Missing required parameters: #{missing_params.join(', ')}"
      }, status: :bad_request
    end

    begin
      if mode == 'test'
        server_status = check_server_status_go(@api_url)

        return render json: {
          success: true,
          message: 'Connection verified successfully',
          data: server_status
        }
      end

      # Create new instance
      instance_data = create_instance_go(@api_url, @admin_token, @instance_name, auth_params)

      register_webhook_after_create(@api_url, instance_data['instance_token'])

      render json: {
        success: true,
        message: 'Instance created successfully',
        data: instance_data['data'],
        instance_uuid: instance_data['instance_uuid'],
        instance_token: instance_data['instance_token']
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Instance creation error: #{e.message}"
      render json: {
        error: e.message
      }, status: :unprocessable_entity
    end
  end

  # CONNECT (Gerar QRCode) - POST /instance/connect
  def connect
    Rails.logger.info "Evolution Go API: Connecting instance #{@instance_name}"

    begin
      connect_data = connect_instance(@api_url, @instance_token, @instance_name)

      render json: {
        success: true,
        message: 'Instance connected successfully',
        data: connect_data['data']
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Instance connection error: #{e.message}"
      render json: {
        error: e.message
      }, status: :unprocessable_entity
    end
  end

  # GET QRCODE - GET /instance/qr
  def qrcode
    Rails.logger.info "Evolution Go API: Getting QR code for instance #{@instance_name}"

    begin
      qrcode_data = get_qrcode_go(@api_url, @instance_token)

      render json: {
        success: true,
        message: 'QR code retrieved successfully',
        data: qrcode_data['data']
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: QR code error: #{e.message}"
      render json: {
        error: e.message
      }, status: :unprocessable_entity
    end
  end

  # FETCH INSTANCE - GET /instance/info/:instanceId
  def fetch
    Rails.logger.info "Evolution Go API: Fetching instance info for #{@instance_uuid}"

    begin
      instance_data = fetch_instance_info(@api_url, @admin_token, @instance_uuid)

      # Update provider_connection based on instance status
      provider_connection = nil
      if @inbox
        channel = @inbox.channel
        connection_status = normalized_connection_status(instance_data['connected'])
        is_connected = connection_status.nil? ? channel.provider_connection['connection'] == 'open' : connection_status

        if connection_status == true
          Rails.logger.info "Evolution Go API: Instance #{@instance_uuid} is connected, updating channel status"

          # Clear reauthorization flag if set
          if channel.reauthorization_required?
            Rails.logger.info "Evolution Go API: Clearing reauthorization flag for channel #{channel.id}"
            channel.reauthorized!
          end

          # Update provider_connection to open
          provider_connection = { 'connection' => 'open', 'error' => nil }
          channel.update_provider_connection!(provider_connection)

          # Update profile picture if JID is available
          if instance_data['jid'].present?
            Rails.logger.info "Evolution Go API: Instance connected, fetching profile picture for #{instance_data['jid']}"
            begin
              phone_number = instance_data['jid'].to_s.split('@').first.gsub(/:\d+$/, '')
              # fetch_and_update_inbox_avatar(phone_number, @api_url, @instance_token) if phone_number.present?
            rescue StandardError => e
              Rails.logger.error "Evolution Go API: Failed to update profile picture: #{e.message}"
              # Don't raise - profile picture update is not critical
            end
          end
        elsif connection_status == false
          Rails.logger.info "Evolution Go API: Instance #{@instance_uuid} is disconnected, updating channel status"

          # Update provider_connection to close
          disconnect_reason = instance_data['disconnect_reason'].presence || 'Not connected'
          provider_connection = { 'connection' => 'close', 'error' => disconnect_reason }
          channel.update_provider_connection!(provider_connection)
        end
      end

      # Convert Evolution Go format to frontend-expected format. Preserve the
      # event-driven snapshot when a partial polling response has no status.
      connection_status = normalized_connection_status(instance_data['connected'])
      current_connection = @inbox&.channel&.provider_connection&.dig('connection')
      is_connected = connection_status.nil? ? current_connection == 'open' : connection_status
      state = is_connected ? 'open' : 'close'

      render json: {
        success: true,
        message: 'Instance info retrieved successfully',
        data: {
          instance: {
            state: state,
            connected: is_connected
          },
          raw: instance_data
        },
        provider_connection: provider_connection
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Fetch instance error: #{e.message}"
      render json: {
        error: e.message
      }, status: :unprocessable_entity
    end
  end

  # LOGOUT - DELETE /instance/logout
  def logout
    Rails.logger.info "Evolution Go API: Logging out instance #{@instance_name}"

    begin
      logout_instance(@api_url, @instance_token)

      render json: {
        success: true,
        message: 'Instance logged out successfully'
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Logout error: #{e.message}"
      render json: {
        error: e.message
      }, status: :unprocessable_entity
    end
  end

  # DELETE - DELETE /instance/delete/:instanceId
  def delete_instance
    Rails.logger.info "Evolution Go API: Deleting instance #{@instance_uuid}"

    if @api_url.blank? || @instance_uuid.blank?
      return render json: {
        error: 'Missing required parameters: api_url and instanceId'
      }, status: :bad_request
    end

    # Evolution Go DELETE /instance/delete/:id is an AuthAdmin route — it requires
    # the global API key (admin_token), NOT the per-instance token. During rollback
    # the channel was never persisted so instance_token is unavailable; fall back to
    # admin_token which is always resolvable via GlobalConfig.
    auth_token = @instance_token.presence || @admin_token

    if auth_token.blank?
      return render json: {
        error: 'Missing credentials: instance_token or admin_token required to delete instance'
      }, status: :bad_request
    end

    begin
      delete_instance_go(@api_url, auth_token, @instance_uuid)

      render json: {
        success: true,
        message: 'Instance deleted successfully'
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Delete instance error: #{e.message}"
      render json: {
        error: e.message
      }, status: :unprocessable_entity
    end
  end

  private

  # Evolution Go versions have returned this field as booleans, strings and,
  # during transient/partial responses, not at all. A read-only browser poll
  # must not turn an unknown response into a persisted disconnect.
  def normalized_connection_status(value)
    return true if value == true || value == 1 || value.to_s.casecmp('true').zero?
    return false if value == false || value == 0 || value.to_s.casecmp('false').zero?

    nil
  end

  def set_instance_params
    # Parâmetros vêm dentro de authorization ou como query params
    auth_params = params[:authorization] || params

    @api_url = auth_params[:api_url].presence || GlobalConfigService.load('EVOLUTION_GO_API_URL', '').to_s.strip
    @admin_token = auth_params[:admin_token].presence || GlobalConfigService.load('EVOLUTION_GO_ADMIN_SECRET', '').to_s.strip
    @instance_name = auth_params[:instance_name] || params[:instanceName] || params[:instanceId]
    @instance_uuid = auth_params[:instance_uuid] || params[:instanceName] || params[:instanceId]
    @instance_token = auth_params[:instance_token]
    @phone_number = auth_params[:phone_number]

    # Para operações que precisam buscar dados da inbox
    # Se instance_uuid está presente mas faltam credenciais, buscar do channel
    return unless @instance_uuid.present? && (@api_url.blank? || @instance_token.blank? || @admin_token.blank?)

    Rails.logger.info "Evolution Go API: Looking for instance with identifier: #{@instance_uuid}"

    # Try to find the channel first by instance UUID
    whatsapp_channel = Channel::Whatsapp.joins(:inbox)
                                        .where(provider: 'evolution_go')
                                        .find { |ch| ch.provider_config['instance_uuid'] == @instance_uuid }

    if whatsapp_channel
      Rails.logger.info "Evolution Go API: Found channel with config: #{whatsapp_channel.provider_config.inspect}"

      # Extract configuration from the channel
      @inbox = whatsapp_channel.inbox
      @api_url = whatsapp_channel.provider_config['api_url'] if @api_url.blank?
      @admin_token = whatsapp_channel.provider_config['admin_token'] if @admin_token.blank?
      @instance_token = whatsapp_channel.provider_config['instance_token'] if @instance_token.blank?
      @instance_name = whatsapp_channel.provider_config['instance_name'] if @instance_name.blank?
    else
      Rails.logger.warn "Evolution Go API: No channel found for instance_uuid: #{@instance_uuid}"
    end
  end

  def create_instance_go(api_url, admin_token, instance_name, auth_params)
    create_url = "#{api_url.chomp('/')}/instance/create"
    Rails.logger.info "Evolution Go API: Creating instance at #{create_url}"

    # Generate UUID for instanceId
    instance_uuid = SecureRandom.uuid
    instance_token = generate_instance_token

    # Get instance settings from frontend
    instance_settings = auth_params[:instance_settings] || {}
    Rails.logger.info "Evolution Go API: Using instance settings: #{instance_settings.inspect}"

    request_body = {
      instanceId: instance_uuid,
      name: instance_name,
      token: instance_token,
      advancedSettings: {
        alwaysOnline: get_setting_value(instance_settings, :alwaysOnline, 'alwaysOnline', true),
        rejectCall: get_setting_value(instance_settings, :rejectCall, 'rejectCall', true),
        readMessages: get_setting_value(instance_settings, :readMessages, 'readMessages', true),
        ignoreGroups: get_setting_value(instance_settings, :ignoreGroups, 'ignoreGroups', false),
        ignoreStatus: get_setting_value(instance_settings, :ignoreStatus, 'ignoreStatus', true)
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

    Rails.logger.info "Evolution Go API: Create instance request body: #{request.body}"

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Create instance response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Create instance response body: #{response.body}"

    raise "Failed to create instance. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    response_data = JSON.parse(response.body)

    # Usar o token retornado pela API Evolution Go (não o gerado localmente)
    api_returned_token = response_data.dig('data', 'token') || response_data['token']

    Rails.logger.info "Evolution Go API: Generated token: #{instance_token}"
    Rails.logger.info "Evolution Go API: API returned token: #{api_returned_token ? '[PRESENT]' : '[MISSING]'}"

    # Se a API não retornou token, usar o que geramos
    final_token = api_returned_token || instance_token
    Rails.logger.info "Evolution Go API: Final token to save: #{final_token ? '[PRESENT]' : '[MISSING]'}"

    # Add generated UUID and API token to response for saving
    response_data['instance_uuid'] = instance_uuid
    response_data['instance_token'] = final_token

    response_data
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Create instance JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API create instance endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Create instance connection error: #{e.class} - #{e.message}"
    raise "Failed to create instance: #{e.message}"
  end

  def check_server_status_go(api_url)
    status_url = "#{api_url.chomp('/')}/server/ok"
    Rails.logger.info "Evolution Go API: Checking server status at #{status_url}"

    uri = URI.parse(status_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 10

    request = Net::HTTP::Get.new(uri)
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Server status response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Server status response body: #{response.body}"

    raise "Server verification failed. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    response_data = JSON.parse(response.body)
    raise "Unexpected server status response: #{response.body}" unless response_data['status'] == 'ok'

    response_data
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Server status JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API server status endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Server status connection error: #{e.class} - #{e.message}"
    raise "Failed to verify connection: #{e.message}"
  end

  def get_qrcode_go(api_url, instance_token)
    qrcode_url = "#{api_url.chomp('/')}/instance/qr"
    Rails.logger.info "Evolution Go API: Getting QR code at #{qrcode_url}"

    uri = URI.parse(qrcode_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Get.new(uri)
    request['apikey'] = instance_token # header com apikey da instancia
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Evolution Go API: QR code response code: #{response.code}"
    Rails.logger.info "Evolution Go API: QR code response body: #{response.body}"

    raise "Failed to get QR code. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: QR code JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API QR code endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: QR code connection error: #{e.class} - #{e.message}"
    raise "Failed to get QR code: #{e.message}"
  end

  def fetch_instance_info(api_url, admin_token, instance_uuid)
    fetch_url = "#{api_url.chomp('/')}/instance/info/#{instance_uuid}"
    Rails.logger.info "Evolution Go API: Fetching instance info at #{fetch_url}"

    uri = URI.parse(fetch_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 10

    request = Net::HTTP::Get.new(uri)
    request['apikey'] = admin_token # header com apikey admin
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Fetch instance response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Fetch instance response body: #{response.body}"

    raise "Failed to fetch instance info. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    response_data = JSON.parse(response.body)

    # A API Evolution Go retorna: { "data": {...}, "message": "success" }
    # Extrair o campo 'data' que contém as informações da instância
    response_data['data'] || response_data
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Fetch instance JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API fetch instance endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Fetch instance connection error: #{e.class} - #{e.message}"
    raise "Failed to fetch instance info: #{e.message}"
  end

  def logout_instance(api_url, instance_token)
    logout_url = "#{api_url.chomp('/')}/instance/logout"
    Rails.logger.info "Evolution Go API: Logging out instance at #{logout_url}"

    uri = URI.parse(logout_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Delete.new(uri)
    request['apikey'] = instance_token # header com apikey da instancia
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Logout response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Logout response body: #{response.body}"

    raise "Failed to logout instance. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body) if response.body.present?
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Logout JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API logout endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Logout connection error: #{e.class} - #{e.message}"
    raise "Failed to logout instance: #{e.message}"
  end

  def delete_instance_go(api_url, instance_token, instance_uuid)
    delete_url = "#{api_url.chomp('/')}/instance/delete/#{instance_uuid}"
    Rails.logger.info "Evolution Go API: Deleting instance at #{delete_url}"

    uri = URI.parse(delete_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Delete.new(uri)
    request['apikey'] = instance_token # header com apikey da instancia
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Delete instance response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Delete instance response body: #{response.body}"

    raise "Failed to delete instance. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body) if response.body.present?
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Delete instance JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API delete endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Delete instance connection error: #{e.class} - #{e.message}"
    raise "Failed to delete instance: #{e.message}"
  end

  def check_and_delete_existing_instance(_api_url, _admin_token, instance_name)
    Rails.logger.info "Evolution Go API: Checking if instance #{instance_name} already exists"
    Rails.logger.info 'Evolution Go API: Currently using instance management approach for Evolution Go'
  rescue StandardError => e
    Rails.logger.info "Evolution Go API: Instance #{instance_name} doesn't exist (#{e.message}), proceeding with creation"
  end

  def generate_instance_token
    # Gerar token no formato UUID padrão
    SecureRandom.uuid
  end

  # Registers the CRM webhook on the freshly created Evolution Go instance so
  # incoming events arrive even before the user opens the QR screen. Failures
  # (e.g. missing BACKEND_URL, transient network error) are logged and swallowed
  # to avoid regressing channel creation — connect_instance is also called when
  # the QR is requested, so the webhook will be retried then.
  def register_webhook_after_create(api_url, instance_token)
    return if api_url.blank? || instance_token.blank?

    # Timeouts curtos: o create já é síncrono e o caminho de QR retenta o
    # connect_instance, então não vale segurar o usuário por 30s aqui.
    connect_instance(api_url, instance_token, nil, open_timeout: 5, read_timeout: 5)
  rescue StandardError => e
    # warn (não error) — o caminho de QR retenta o connect_instance, então uma
    # falha aqui não é um problema de produção que deva paginar.
    Rails.logger.warn "Evolution Go API: Eager webhook registration failed (will retry on QR open): #{e.class} - #{e.message}"
  end

  def get_setting_value(settings, symbol_key, string_key, default_value)
    return settings[symbol_key] if settings.key?(symbol_key)
    return settings[string_key] if settings.key?(string_key)

    default_value
  end

  def fetch_and_update_inbox_avatar(phone_number, api_url, instance_token)
    return unless @inbox && phone_number.present?

    Rails.logger.info "Evolution Go API: Fetching avatar from API for phone #{phone_number}"

    # Call Evolution Go /user/avatar endpoint
    avatar_url_endpoint = "#{api_url.chomp('/')}/user/avatar"

    uri = URI.parse(avatar_url_endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = instance_token
    request['Content-Type'] = 'application/json'
    request.body = {
      number: phone_number,
      preview: false
    }.to_json

    Rails.logger.info "Evolution Go API: Avatar request to #{avatar_url_endpoint} for number #{phone_number}"

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Avatar response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Avatar response body: #{response.body[0..200]}" # Log first 200 chars

    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.warn "Evolution Go API: Failed to fetch avatar. Status: #{response.code}"
      return
    end

    response_data = JSON.parse(response.body)

    # Evolution Go returns: { "data": { "url": "https://..." }, "message": "success" }
    avatar_url = response_data.dig('data', 'url') || response_data['url']

    if avatar_url.present?
      Rails.logger.info "Evolution Go API: Avatar URL found: #{avatar_url[0..50]}..."

      # Download and attach avatar
      downloaded_image = URI.open(avatar_url)
      filename = "profile_#{@inbox.id}_#{Time.now.to_i}.jpg"

      @inbox.avatar.attach(
        io: downloaded_image,
        filename: filename,
        content_type: 'image/jpeg'
      )

      Rails.logger.info "Evolution Go API: Successfully updated inbox #{@inbox.id} avatar via fetch endpoint"
    else
      Rails.logger.info "Evolution Go API: No avatar URL found in response"
    end
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Avatar response JSON parse error: #{e.message}"
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Failed to fetch and update avatar: #{e.class} - #{e.message}"
    raise
  end
end
