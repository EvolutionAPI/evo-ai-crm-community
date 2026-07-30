class AgentBots::N8nRequestService
  require 'net/http'
  require 'json'
  require_relative 'conversation_finder'
  require_relative 'message_creator'

  def initialize(agent_bot, payload)
    @agent_bot = agent_bot
    @payload = payload
  end

  def perform
    return if @agent_bot.outgoing_url.blank?

    unless should_process_message?
      Rails.logger.debug { '[AgentBot N8n] Skipping message - not eligible for bot processing' }
      return
    end

    Rails.logger.info "[AgentBot N8n] Starting request to N8n: #{@agent_bot.name}"

    begin
      response = make_http_request
      handle_response(response)
    rescue StandardError => e
      Rails.logger.error "[AgentBot N8n] Error: #{e.message}"
      Rails.logger.error "[AgentBot N8n] Backtrace: #{e.backtrace.first(5).join("\n")}"
    end
  end

  private

  def should_process_message?
    event_valid = %w[message_created message_updated].include?(@payload[:event])
    Rails.logger.debug { "[AgentBot N8n] Event validation: #{@payload[:event]} -> #{event_valid}" }
    return false unless event_valid

    message_type = @payload[:message_type]
    # rubocop:disable Style/NumericPredicate
    # Note: message_type can be string or integer, so we can't use .zero? here
    is_incoming = message_type == 'incoming' || message_type == 0 || message_type == '0'
    # rubocop:enable Style/NumericPredicate
    Rails.logger.debug { "[AgentBot N8n] Message type check: #{message_type} -> incoming: #{is_incoming}" }

    log_message_validation(event_valid, is_incoming, message_type)

    event_valid && is_incoming
  end

  def log_message_validation(event_valid, is_incoming, message_type)
    Rails.logger.info '[AgentBot N8n] Message validation:'
    Rails.logger.info "[AgentBot N8n]   Event: #{@payload[:event]} (valid: #{event_valid})"
    Rails.logger.info "[AgentBot N8n]   Message type: #{message_type} (incoming: #{is_incoming})"

    result = event_valid && is_incoming
    Rails.logger.info "[AgentBot N8n] Should process: #{result} (event: #{event_valid}, incoming: #{is_incoming})"
  end

  def make_http_request
    uri = URI(@agent_bot.outgoing_url)
    http = setup_http_client(uri)
    request = build_http_request(uri)

    log_request_details(request)
    response = http.request(request)
    log_response_details(response)

    response
  end

  def setup_http_client(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 10
    http.open_timeout = 5
    http
  end

  def build_http_request(uri)
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'

    # Basic auth pair, from the vault when the bot references one and from the
    # colon-separated api_key otherwise. The header on the wire is unchanged.
    if basic_auth
      auth = Base64.strict_encode64("#{basic_auth[0]}:#{basic_auth[1]}")
      request['Authorization'] = "Basic #{auth}"
    end

    request.body = build_n8n_payload.to_json
    request
  end

  def log_request_details(request)
    Rails.logger.debug { "[AgentBot N8n] Request URL: #{@agent_bot.outgoing_url}" }
    Rails.logger.debug { "[AgentBot N8n] Request Headers: #{request.to_hash}" }
    Rails.logger.debug { "[AgentBot N8n] Request Body: #{request.body}" }
  end

  def log_response_details(response)
    Rails.logger.info "[AgentBot N8n] Response Status: #{response.code} #{response.message}"
    Rails.logger.debug { "[AgentBot N8n] Response Headers: #{response.to_hash}" }
    Rails.logger.debug { "[AgentBot N8n] Response Body: #{response.body}" }
  end

  def build_n8n_payload
    conversation = find_conversation_from_payload

    {
      chatInput: extract_message_content,
      sessionId: extract_session_id(conversation),
      fromMe: false, # Always false for incoming messages
      instanceName: extract_instance_name,
      serverUrl: extract_server_url,
      apiKey: extract_api_key,
      evoai_crm_event: @payload[:event],
      evoai_crm_data: @payload,
      agent_bot_id: @agent_bot.id,
      agent_bot_name: @agent_bot.name,
      contactId: extract_contact_id,
      contactName: extract_contact_name,
      inboxId: extract_inbox_id,
      conversationId: extract_conversation_id
    }
  end

  def find_conversation_from_payload
    conversation_id = @payload.dig(:conversation, :id) || @payload[:conversation_id]
    return nil unless conversation_id

    Conversation.find_by(id: conversation_id)
  end

  def extract_session_id(conversation)
    return SecureRandom.uuid unless conversation

    # Use conversation ID as session ID for consistency
    "evolution_#{conversation.id}"
  end

  def extract_instance_name
    inbox = @payload.dig(:inbox, :name) || @payload[:inbox_name] || 'evolution'
    inbox
  end

  def extract_server_url
    # Get the server URL from Rails configuration or environment
    Rails.application.routes.default_url_options[:host] || 'localhost'
  end

  def extract_api_key
    # An api key, not a basic auth pair: a colon means the value carries
    # credentials and belongs in the Authorization header instead.
    return nil if basic_auth

    AgentBots::CredentialResolution.api_key_for(@agent_bot)
  end

  # Once per dispatch: each call hits the vault, and this service asked three
  # times per outgoing message.
  def basic_auth
    return @basic_auth if defined?(@basic_auth)

    @basic_auth = AgentBots::CredentialResolution.basic_auth_for(@agent_bot)
  end

  def extract_contact_id
    @payload.dig(:sender, :id)&.to_s ||
      @payload[:contact_id]&.to_s ||
      @payload.dig(:contact, :id)&.to_s
  end

  def extract_contact_name
    @payload.dig(:sender, :name) ||
      @payload.dig(:contact, :name) ||
      @payload[:contact_name] ||
      'Unknown Contact'
  end

  def extract_inbox_id
    @payload.dig(:inbox, :id)&.to_s ||
      @payload[:inbox_id]&.to_s ||
      @payload.dig(:conversation, :inbox_id)&.to_s
  end

  def extract_conversation_id
    @payload.dig(:conversation, :id)&.to_s ||
      @payload[:conversation_id]&.to_s
  end

  def extract_message_content
    case @payload[:event]
    when 'message_created', 'message_updated'
      @payload[:content] || 'No content'
    when 'conversation_opened'
      'Conversation opened'
    when 'conversation_resolved'
      'Conversation resolved'
    when 'webwidget_triggered'
      'Widget triggered'
    else
      'Unknown event'
    end
  end

  def handle_response(response)
    return unless response

    status_code = response.code.to_i
    Rails.logger.info "[AgentBot N8n] Response Status: #{response.code} #{response.message}"

    if success_response?(status_code)
      handle_success_response(response)
    else
      handle_error_response(response)
    end
  end

  def success_response?(status_code)
    status_code >= 200 && status_code < 300
  end

  def handle_success_response(response)
    Rails.logger.info "[AgentBot N8n] Success: #{response.code}"

    begin
      parsed_response = JSON.parse(response.body)
      Rails.logger.info "[AgentBot N8n] Parsed Response: #{parsed_response}"
      process_bot_response(parsed_response)
    rescue JSON::ParserError => e
      Rails.logger.error "[AgentBot N8n] JSON parsing failed: #{e.message}"
    end
  end

  def handle_error_response(response)
    Rails.logger.error "[AgentBot N8n] Error Response: #{response.code} - #{response.body}"
  end

  def process_bot_response(parsed_response)
    # Extract message from N8n response
    # N8n typically returns { output: "message" } or { answer: "message" }
    message_content = parsed_response['output'] || parsed_response['answer'] || parsed_response['message']
    return unless message_content

    conversation = AgentBots::ConversationFinder.new(@agent_bot, @payload).find_conversation
    return unless conversation

    # Add signature if configured
    final_content = build_message_with_signature(message_content)
    Rails.logger.info "[AgentBot N8n] Bot Response Message: #{final_content}"

    AgentBots::MessageCreator.new(@agent_bot).create_bot_reply(final_content, conversation)
  end

  def build_message_with_signature(content)
    return content unless @agent_bot.message_signature.present?

    "#{content}\n\n#{@agent_bot.message_signature}"
  end
end
