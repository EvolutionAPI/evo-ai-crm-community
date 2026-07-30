# Service to generate a response for a Facebook comment using the configured agent bot
# This service calls the agent bot's API/webhook to generate a response
require 'net/http'
require 'uri'
require 'json'
require 'securerandom'

class Facebook::Moderation::ResponseGeneratorService
  attr_reader :conversation, :message, :agent_bot

  def initialize(conversation:, message:, agent_bot:)
    @conversation = conversation
    @message = message
    @agent_bot = agent_bot
  end

  def generate
    return nil unless agent_bot.present?
    return nil unless message.content.present?

    Rails.logger.info "[Facebook Moderation] Generating response using agent bot #{agent_bot.id}"

    # Build payload similar to what AgentBotListener sends
    payload = build_payload

    # Call agent bot based on provider type
    response_content = call_agent_bot(payload)

    Rails.logger.info "[Facebook Moderation] Generated response: #{response_content&.first(100)}..."
    response_content
  rescue StandardError => e
    Rails.logger.error "[Facebook Moderation] Error generating response: #{e.message}"
    Rails.logger.error(e.backtrace.join("\n"))
    nil
  end

  private

  def build_payload
    {
      event: 'message_created',
      message: message.webhook_data,
      conversation: conversation.webhook_data,
      account: {},
      inbox: conversation.inbox.webhook_data,
      contact: conversation.contact.webhook_data
    }
  end

  def call_agent_bot(payload)
    case agent_bot.bot_provider
    when 'webhook'
      call_webhook_bot(payload)
    when 'n8n', 'n8n_provider'
      call_n8n_bot(payload)
    when 'evo_ai_provider'
      call_evo_ai_bot(payload)
    else
      call_http_bot(payload)
    end
  end

  def call_webhook_bot(payload)
    # For webhook bots, make a synchronous call
    return nil unless agent_bot.outgoing_url.present?

    uri = URI(agent_bot.outgoing_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 30
    http.open_timeout = 10

    request = Net::HTTP::Post.new(uri.path)
    request['Content-Type'] = 'application/json'
    request.body = payload.to_json

    response = http.request(request)

    return nil unless response.code == '200'

    parsed = JSON.parse(response.body) rescue {}
    extract_response_content(parsed)
  end

  def call_n8n_bot(payload)
    # N8n bots return { output: "message" } or { answer: "message" }
    return nil unless agent_bot.outgoing_url.present?

    uri = URI(agent_bot.outgoing_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 30
    http.open_timeout = 10

    request = Net::HTTP::Post.new(uri.path)
    request['Content-Type'] = 'application/json'
    request.body = payload.to_json

    response = http.request(request)

    return nil unless response.code == '200'

    parsed = JSON.parse(response.body) rescue {}
    # N8n typically returns { output: "message" } or { answer: "message" }
    content = parsed['output'] || parsed['answer'] || parsed['message']
    content.to_s.strip.presence
  end

  def call_evo_ai_bot(payload)
    # Evo AI provider uses JSON-RPC format (same as HttpRequestService)
    return nil unless agent_bot.outgoing_url.present?

    uri = URI(agent_bot.outgoing_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 30
    http.open_timeout = 10

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    # Same reason as the HTTP request service: gating on the inline column left a
    # vault-only bot with no Authorization header at all.
    moderation_key = AgentBots::CredentialResolution.api_key_for(agent_bot)
    request['Authorization'] = "Bearer #{moderation_key}" if moderation_key.present?

    # Build JSON-RPC payload (same format as HttpRequestService)
    jsonrpc_payload = {
      jsonrpc: '2.0',
      id: "req-#{SecureRandom.uuid[0..7]}",
      method: 'message/send',
      params: {
        contextId: conversation.id.to_s,
        message: {
          role: 'user',
          parts: [{ type: 'text', text: message.content }],
          messageId: message.id.to_s
        },
        metadata: {
          evoai_crm_event: 'message_created',
          evoai_crm_data: payload,
          agent_bot_id: agent_bot.id,
          agent_bot_name: agent_bot.name,
          contactId: conversation.contact.id.to_s,
          contactName: conversation.contact.name,
          inboxId: conversation.inbox.id.to_s
        }
      }
    }

    request.body = jsonrpc_payload.to_json

    Rails.logger.info "[Facebook Moderation] Making JSON-RPC request to #{agent_bot.outgoing_url}"
    response = http.request(request)

    return nil unless response.code == '200'

    parsed = JSON.parse(response.body) rescue {}
    # Extract from artifacts format (same as ResponseProcessor)
    extract_response_from_artifacts(parsed)
  end

  def call_http_bot(payload)
    # Generic HTTP bot call - use evo_ai format
    call_evo_ai_bot(payload)
  end

  def extract_response_content(parsed_response)
    # Try different response formats
    content = parsed_response['message'] ||
              parsed_response['output'] ||
              parsed_response['answer'] ||
              parsed_response.dig('data', 'message') ||
              parsed_response.dig('response', 'message')

    # If content is in artifacts format (like evo-ai)
    if parsed_response['artifacts'].present?
      artifacts = parsed_response['artifacts']
      text_artifacts = artifacts.select { |a| a['type'] == 'text' || a['mime']&.start_with?('text/') }
      content = text_artifacts.map { |a| a['text'] || a['data'] }.join("\n\n") if text_artifacts.any?
    end

    content.to_s.strip.presence
  end

  def extract_response_from_artifacts(parsed_response)
    # Extract from JSON-RPC result.artifacts format (same as ResponseProcessor)
    Rails.logger.info "[Facebook Moderation] Parsed response keys: #{parsed_response.keys.inspect}"

    artifacts = parsed_response.dig('result', 'artifacts')
    Rails.logger.info "[Facebook Moderation] Artifacts found: #{artifacts.present?}, count: #{artifacts&.length || 0}"

    return nil unless artifacts&.any?

    artifact = artifacts.first
    Rails.logger.info "[Facebook Moderation] First artifact keys: #{artifact.keys.inspect}"
    Rails.logger.info "[Facebook Moderation] First artifact parts: #{artifact['parts']&.inspect}"

    return nil unless artifact['parts']&.any?

    text_part = artifact['parts'].find { |p| p['type'] == 'text' }
    content = text_part&.dig('text')

    Rails.logger.info "[Facebook Moderation] Extracted text content: #{content&.first(100)}..."

    return nil unless content.present?

    # Add signature if configured
    if agent_bot.message_signature.present?
      "#{agent_bot.message_signature}\n\n#{content}"
    else
      content
    end
  end
end

