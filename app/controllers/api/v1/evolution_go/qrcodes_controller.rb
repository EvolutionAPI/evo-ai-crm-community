class Api::V1::EvolutionGo::QrcodesController < Api::V1::BaseController
  include EvolutionGoConcern

  require_permissions({
    show: 'inboxes.read',
    create: 'inboxes.update'
  })

  before_action :set_instance_params, only: [:show, :create]

  def show
    Rails.logger.info "Evolution Go API: Getting QR code for instance #{@instance_uuid}"

    begin
      if @api_url.blank? || @instance_token.blank? || @instance_uuid.blank?
        return render json: {
          error: 'Missing required parameters: api_url, instance_token, instance_uuid'
        }, status: :bad_request
      end

      # Connect instance first to configure webhook and events
      connect_instance(@api_url, @instance_token)

      # Get QR code using Evolution Go API
      qrcode_data = get_qrcode_go(@api_url, @instance_token)

      render json: qrcode_data
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: QR code error: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def create
    Rails.logger.info "Evolution Go API: QR code refresh called with params: #{params.inspect}"

    begin
      # Resolve credenciais via canal (com fallback para Admin Settings) quando
      # o frontend mandar apenas o instance_uuid — canais legados podem ter
      # api_url/instance_token vazios em provider_config (EVO-984).
      auth_params = params[:qrcode] || params
      instance_uuid = auth_params[:instance_uuid].presence || params[:id]

      api_url, instance_token = resolve_qrcode_credentials(auth_params, instance_uuid)

      if api_url.blank? || instance_token.blank? || instance_uuid.blank?
        return render json: {
          error: 'Missing required parameters: api_url, instance_token, instance_uuid'
        }, status: :bad_request
      end

      Rails.logger.info "Evolution Go API: Getting QR code for instance #{instance_uuid}"

      # Get QR code using Evolution Go API
      qrcode_data = get_qrcode_go(api_url, instance_token)

      render json: {
        success: true,
        qrcode: qrcode_data
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: QR code error: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  private

  def resolve_qrcode_credentials(auth_params, instance_uuid)
    api_url = auth_params[:api_url].presence
    instance_token = auth_params[:instance_token].presence

    return [api_url, instance_token] if api_url.present? && instance_token.present?
    return [api_url, instance_token] if instance_uuid.blank?

    channel = Channel::Whatsapp.joins(:inbox)
                               .where(provider: 'evolution_go')
                               .where('provider_config @> ?', { instance_uuid: instance_uuid }.to_json)
                               .first
    return [api_url, instance_token] unless channel

    creds = evolution_go_credentials_for(channel)
    [api_url || creds[:api_url], instance_token || creds[:instance_token]]
  end

  def set_instance_params
    # Para o método show, recebe instance_name ou instance_uuid da URL (params[:id])
    identifier = params[:id] || params[:instance_uuid] || params[:instance_name]

    # Busca diretamente pelo Channel::Whatsapp para evitar problemas com associação polimórfica
    return if identifier.blank?

    Rails.logger.info "Evolution Go API: Looking for instance with identifier: #{identifier}"

    # Try to find by instance_name first (most common case)
    whatsapp_channel = Channel::Whatsapp.joins(:inbox)
                                        .where(provider: 'evolution_go')
                                        .where('provider_config @> ?', { instance_name: identifier }.to_json)
                                        .first

    # If not found by name, try by UUID
    if whatsapp_channel.nil?
      whatsapp_channel = Channel::Whatsapp.joins(:inbox)
                                          .where(provider: 'evolution_go')
                                          .where('provider_config @> ?', { instance_uuid: identifier }.to_json)
                                          .first
    end

    return unless whatsapp_channel

    Rails.logger.info "Evolution Go API: Found channel with config: #{whatsapp_channel.provider_config.inspect}"

    creds = evolution_go_credentials_for(whatsapp_channel)
    @inbox = whatsapp_channel.inbox
    @api_url = creds[:api_url]
    @instance_token = creds[:instance_token]
    @instance_uuid = creds[:instance_uuid]
    @instance_name = creds[:instance_name]
  end

  def get_qrcode_go(api_url, instance_token)
    # Evolution Go API endpoint: GET /instance/qr
    qrcode_url = "#{api_url.chomp('/')}/instance/qr"
    Rails.logger.info "Evolution Go API: Getting QR code from #{qrcode_url}"

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

    parsed_response = JSON.parse(response.body)

    # Evolution Go API retorna:
    # {
    #   "data": {
    #     "qrcode": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA...",
    #     "code": "2@C7BUZArTUkKYRlxxRvQxa3+qoKLOywu5QcewxlFtU1bbG2..."
    #   },
    #   "message": "success"
    # }
    #
    # Builds atuais respondem com chaves minúsculas; versões antigas mandavam
    # "Qrcode"/"Code". Ler só a forma capitalizada devolve nil silenciosamente
    # (a request é 200 e o corpo chega inteiro — só o mapeamento perde o QR),
    # então aceitamos as duas grafias.
    data = parsed_response['data'].is_a?(Hash) ? parsed_response['data'] : parsed_response

    {
      base64: data['qrcode'] || data['Qrcode'],
      code: data['code'] || data['Code'],
      connected: false
    }

  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: QR code JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API QR code endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: QR code connection error: #{e.class} - #{e.message}"
    raise "Failed to get QR code: #{e.message}"
  end
end
