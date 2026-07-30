class AgentBots::HttpRequestService
  require 'securerandom'
  require 'net/http'
  require 'json'
  require_relative 'conversation_finder'
  require_relative 'message_creator'
  require_relative 'response_processor'

  def initialize(agent_bot, payload)
    @agent_bot = agent_bot
    # `with_indifferent_access` (CB): o payload chega ora com SYMBOL keys (webhook_data
    # nativo), ora com STRING keys (quando passou por serialização JSON no caminho do
    # evento/job). Os helpers abaixo usam `@payload.dig(:conversation, :id)` (symbol);
    # com string keys o dig FALHAVA → find_conversation_from_payload não achava a
    # conversa → extract_context_id caía no fallback SecureRandom.uuid → contextId
    # ALEATÓRIO a cada mensagem → session_id novo no processor → o agente "esquecia" o
    # histórico e repetia a 1ª resposta ("preso na primeira mensagem"). Indifferent
    # access faz symbol E string keys funcionarem → contextId estável por conversa.
    @payload = payload.respond_to?(:with_indifferent_access) ? payload.with_indifferent_access : payload
  end

  def perform
    return if @agent_bot.outgoing_url.blank?

    unless should_process_message?
      Rails.logger.debug { '[AgentBot HTTP] Skipping message - not eligible for bot processing' }
      return
    end

    Rails.logger.info "[AgentBot HTTP] Starting request to bot: #{@agent_bot.name}"
    Rails.logger.info "[AgentBot HTTP] Outgoing URL: #{@agent_bot.outgoing_url}"
    # Reports the credential the request will ACTUALLY use, not the inline column:
    # for a bot that references the vault, the old lines said "no key" while the
    # request went out authenticated (and vice versa after retirement).
    Rails.logger.info "[AgentBot HTTP] Vault reference: #{@agent_bot.credential_id.present?}"

    begin
      response = make_http_request
      Rails.logger.info "[AgentBot HTTP] ✅ Request successful: #{response.code} #{response.message}"
      handle_response(response)
    rescue StandardError => e
      Rails.logger.error "[AgentBot HTTP] ❌ Error: #{e.message}"
      Rails.logger.error "[AgentBot HTTP] Error class: #{e.class}"
      Rails.logger.error "[AgentBot HTTP] Backtrace: #{e.backtrace.first(10).join("\n")}"
    end
  end

  private

  def should_process_message?
    event_valid = %w[message_created message_updated inactivity_action].include?(@payload[:event])
    Rails.logger.debug { "[AgentBot HTTP] Event validation: #{@payload[:event]} -> #{event_valid}" }
    return false unless event_valid

    message_type = @payload[:message_type]
    # rubocop:disable Style/NumericPredicate
    # Note: message_type can be string or integer, so we can't use .zero? here
    is_incoming = message_type == 'incoming' || message_type == 0 || message_type == '0'
    # rubocop:enable Style/NumericPredicate
    Rails.logger.debug { "[AgentBot HTTP] Message type check: #{message_type} -> incoming: #{is_incoming}" }

    log_message_validation(event_valid, is_incoming, message_type)

    event_valid && is_incoming
  end

  def log_message_validation(event_valid, is_incoming, message_type)
    Rails.logger.info '[AgentBot HTTP] Message validation:'
    Rails.logger.info "[AgentBot HTTP]   Event: #{@payload[:event]} (valid: #{event_valid})"
    Rails.logger.info "[AgentBot HTTP]   Message type: #{message_type} (incoming: #{is_incoming})"

    result = event_valid && is_incoming
    Rails.logger.info "[AgentBot HTTP] Should process: #{result} (event: #{event_valid}, incoming: #{is_incoming})"
  end

  def make_http_request
    uri = URI(@agent_bot.outgoing_url)
    Rails.logger.info "[AgentBot HTTP] Making request to: #{uri.host}:#{uri.port}#{uri.path}"

    http = setup_http_client(uri)
    request = build_http_request(uri)

    log_request_details(request)

    Rails.logger.info "[AgentBot HTTP] Sending HTTP request..."
    response = http.request(request)
    log_response_details(response)

    # Raise error for non-2xx responses
    if response.code.to_i >= 400
      error_msg = "HTTP #{response.code}: #{response.message}"
      error_msg += " - #{response.body}" if response.body.present?
      Rails.logger.error "[AgentBot HTTP] Request failed: #{error_msg}"
      raise StandardError.new(error_msg)
    end

    response
  end

  def setup_http_client(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 120
    http.open_timeout = 10
    http
  end

  def build_http_request(uri)
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'

    # The credential comes from the resolver, never from the inline column
    # directly: gating on `api_key.present?` left a bot that references the vault
    # and holds no inline key sending NO X-API-Key at all (review of 2026-07-29).
    #
    # No fragment of the key is logged: for a key under ~21 characters the old
    # first-11-plus-last-10 preview printed the whole secret. The length alone
    # carries the diagnostic value.
    api_key = AgentBots::CredentialResolution.api_key_for(@agent_bot)
    if api_key.present?
      Rails.logger.debug "[AgentBot HTTP] Using API Key (length: #{api_key.length})"
      request['X-API-Key'] = api_key
    else
      Rails.logger.warn "[AgentBot HTTP] No API key resolved for agent bot #{@agent_bot.id}"
    end

    request.body = build_jsonrpc_payload.to_json
    request
  end

  def log_request_details(request)
    Rails.logger.debug { "[AgentBot HTTP] Request URL: #{@agent_bot.outgoing_url}" }
    Rails.logger.debug { "[AgentBot HTTP] Request Headers: #{request.to_hash}" }
    Rails.logger.debug { "[AgentBot HTTP] Request Body: #{request.body}" }
  end

  def log_response_details(response)
    Rails.logger.info "[AgentBot HTTP] Response Status: #{response.code} #{response.message}"
    Rails.logger.info "[AgentBot HTTP] Response Headers: #{response.to_hash.inspect}"

    if response.code.to_i >= 400
      Rails.logger.error "[AgentBot HTTP] ❌ Error Response Body: #{response.body}"
    else
      Rails.logger.debug { "[AgentBot HTTP] Response Body: #{response.body}" }
    end
  end

  def build_jsonrpc_payload
    {
      jsonrpc: '2.0',
      id: generate_call_id,
      method: 'message/send',
      params: build_params
    }
  end

  def generate_call_id
    "req-#{SecureRandom.uuid[0..7]}"
  end

  def build_params
    {
      contextId: extract_context_id,
      userId: extract_contact_id,  # Send contact_id as userId (for session user_id)
      message: build_message,
      metadata: build_metadata
    }
  end

  def build_message
    {
      role: 'user',
      parts: [{ type: 'text', text: extract_message_content }],
      messageId: extract_message_id
    }
  end

  def build_metadata
    contact = find_contact_from_payload
    metadata = {
      evoai_crm_event: @payload[:event],
      evoai_crm_data: @payload,
      agent_bot_id: @agent_bot.id,
      agent_bot_name: @agent_bot.name,
      contactId: extract_contact_id,
      contactName: extract_contact_name,
      inboxId: extract_inbox_id
    }

    # Add full contact data if contact is found
    if contact
      metadata[:contact] = build_contact_data(contact)
    end

    metadata
  end

  def find_contact_from_payload
    contact_id = extract_contact_id
    return nil unless contact_id

    begin
      Contact.find_by(id: contact_id)
    rescue StandardError => e
      Rails.logger.error "[AgentBot HTTP] Error finding contact: #{e.message}"
      nil
    end
  end

  def build_contact_data(contact)
    {
      id: contact.id.to_s,
      name: contact.name,
      email: contact.email,
      phone_number: contact.phone_number,
      identifier: contact.identifier,
      type: contact.type,
      contact_type: contact.contact_type,
      blocked: contact.blocked,
      location: contact.location,
      country_code: contact.country_code,
      industry: contact.industry,
      website: contact.website,
      tax_id: contact.tax_id,
      last_activity_at: contact.last_activity_at&.iso8601,
      created_at: contact.created_at&.iso8601,
      updated_at: contact.updated_at&.iso8601,
      additional_attributes: contact.additional_attributes || {},
      custom_attributes: contact.custom_attributes || {},
      labels: contact.labels.pluck(:name),
      companies: contact.companies.map { |c| { id: c.id.to_s, name: c.name } },
      pipelines: build_pipeline_data(contact)
    }
  end

  def build_pipeline_data(contact)
    contact.pipeline_items.includes(:pipeline, :pipeline_stage, :tasks).map do |item|
      {
        id: item.id.to_s,
        pipeline_id: item.pipeline_id.to_s,
        pipeline_name: item.pipeline.name,
        stage_id: item.pipeline_stage_id.to_s,
        stage_name: item.pipeline_stage.name,
        stage_position: item.pipeline_stage.position,
        status: item.completed? ? 'completed' : 'active',
        entered_at: item.entered_at&.iso8601,
        completed_at: item.completed_at&.iso8601,
        custom_fields: item.custom_fields || {},
        tasks: item.tasks.map { |task| { id: task.id.to_s, title: task.title, status: task.status } }
      }
    end
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

  def extract_message_content
    case @payload[:event]
    when 'message_created', 'message_updated'
      @payload[:content] || 'No content'
    when 'inactivity_action'
      @payload[:content] || 'Generate an appropriate message to re-engage the customer'
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

  def extract_context_id
    # ALWAYS use conversation UUID (not display_id) for contextId
    # The session_id will be built as {conversation_uuid}_{agent_id} in the AI processor
    # This ensures unique session IDs and avoids conflicts

    conversation = find_conversation_from_payload

    if conversation&.id
      Rails.logger.info "[AgentBot HTTP] Using conversation UUID as contextId: #{conversation.id}"
      return conversation.id.to_s
    end

    # Fallback to random UUID if conversation not found
    Rails.logger.warn "[AgentBot HTTP] Could not find conversation, generating random UUID"
    SecureRandom.uuid
  end

  def find_conversation_from_payload
    # Try multiple strategies to find the conversation

    # Strategy 1: Try conversation ID from payload (could be UUID or display_id)
    conversation_id = @payload.dig(:conversation, :id) || @payload[:conversation_id]

    if conversation_id
      # Try finding by UUID first
      conversation = Conversation.find_by(id: conversation_id)
      if conversation
        Rails.logger.info "[AgentBot HTTP] Found conversation by UUID: #{conversation.id}"
        return conversation
      end

      # If not found and it's a number, try finding by display_id
      if conversation_id.to_s.match?(/\A\d+\z/)
        Rails.logger.debug "[AgentBot HTTP] Trying to find conversation by display_id: #{conversation_id}"
        conversation = Conversation.find_by(display_id: conversation_id)
        if conversation
          Rails.logger.info "[AgentBot HTTP] Found conversation by display_id: #{conversation.id}"
          return conversation
        end
      end
    end

    # Strategy 2: Try finding via message ID
    message_id = @payload[:id] || @payload[:message_id]
    if message_id
      Rails.logger.debug "[AgentBot HTTP] Trying to find conversation via message ID: #{message_id}"
      message = Message.find_by(id: message_id)
      if message&.conversation
        Rails.logger.info "[AgentBot HTTP] Found conversation via message: #{message.conversation.id}"
        return message.conversation
      end
    end

    # Strategy 3: Try finding via conversation display_id from payload
    display_id = @payload.dig(:conversation, :display_id)
    if display_id
      Rails.logger.debug "[AgentBot HTTP] Trying to find conversation by display_id from payload: #{display_id}"
      conversation = Conversation.find_by(display_id: display_id)
      if conversation
        Rails.logger.info "[AgentBot HTTP] Found conversation by display_id from payload: #{conversation.id}"
        return conversation
      end
    end

    Rails.logger.warn "[AgentBot HTTP] Could not find conversation from payload"
    nil
  end

  def extract_message_id
    @payload[:id]&.to_s ||
      @payload[:message_id]&.to_s ||
      SecureRandom.uuid
  end

  def handle_response(response)
    AgentBots::ResponseProcessor.new(@agent_bot, @payload).process(response)
  end
end
