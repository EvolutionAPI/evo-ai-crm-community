class Integrations::Openai::GlobalProcessorService
  include ActiveModel::Model

  attr_accessor :account, :event

  ALLOWED_EVENT_NAMES = %w[rephrase summarize reply_suggestion fix_spelling_grammar shorten expand make_friendly make_formal simplify analyze_sentiment generate_prompt review_prompt].freeze

  def initialize(account:, event:)
    @account = account
    @event = event
  end

  def perform
    return nil unless valid_event_name?
    return nil unless global_config_available?

    result = send("#{event_name}_message")

    # For analyze_sentiment, wrap result in message format for consistency
    if event_name == 'analyze_sentiment' && result.is_a?(Hash)
      { message: result.to_json }
    else
      result
    end
  end

  private

  def event_name
    event['name']
  end

  def valid_event_name?
    ALLOWED_EVENT_NAMES.include?(event_name)
  end

  def global_config_available?
    api_url.present? && api_key.present? && gpt_model.present?
  end

  def api_url
    @api_url ||= GlobalConfigService.load('OPENAI_API_URL', nil)
  end

  # The registry is the single source; the pre-registry global/hook chain is the
  # last link inside the resolver, so unmigrated installations keep working.
  def api_key
    @api_key ||= Ai::CredentialResolver.resolve_key(for_consumer: :inbox_assist)
  end

  def gpt_model
    @gpt_model ||= GlobalConfigService.load('OPENAI_MODEL', 'gpt-4.1-nano')
  end

  def conversation
    return nil unless event['data']['conversation_display_id']

    # Try to find by UUID first (mobile app and frontend send UUID)
    # Fallback to display_id for backward compatibility
    conversation_id = event['data']['conversation_display_id']
    @conversation ||= Conversation.find_by(id: conversation_id) ||
                      Conversation.find_by(display_id: conversation_id)
  end

  def account_language
    @account_language ||= GlobalConfigService.load('DEFAULT_LOCALE', 'english')
  end

  def language_instruction
    if account_language && account_language != 'english'
      "Please respond in #{account_language}. If you're unsure about the language, use #{account_language} as the default."
    else
      'Ensure that the reply should be in user language.'
    end
  end

  def get_prompt(prompt_type)
    case prompt_type.to_s
    when 'reply'
      GlobalConfigService.load('OPENAI_PROMPT_REPLY',
                               'Please suggest a reply to the following conversation between support agents and customer. Don\'t expose that you are an AI model, respond "Couldn\'t generate the reply" in cases where you can\'t answer. Reply in the user\'s language.')
    when 'summary'
      GlobalConfigService.load('OPENAI_PROMPT_SUMMARY',
                               'Please summarize the key points from the following conversation between support agents and customer as bullet points for the next support agent looking into the conversation. Reply in the user\'s language.')
    when 'rephrase'
      GlobalConfigService.load('OPENAI_PROMPT_REPHRASE',
                               'You are a helpful support agent. Please rephrase the following response. Ensure that the reply should be in user language.')
    when 'fix_spelling_grammar'
      GlobalConfigService.load('OPENAI_PROMPT_FIX_GRAMMAR',
                               'You are a helpful support agent. Please fix the spelling and grammar of the following response. Ensure that the reply should be in user language.')
    when 'shorten'
      GlobalConfigService.load('OPENAI_PROMPT_SHORTEN',
                               'You are a helpful support agent. Please shorten the following response. Ensure that the reply should be in user language.')
    when 'expand'
      GlobalConfigService.load('OPENAI_PROMPT_EXPAND',
                               'You are a helpful support agent. Please expand the following response. Ensure that the reply should be in user language.')
    when 'make_friendly'
      GlobalConfigService.load('OPENAI_PROMPT_FRIENDLY',
                               'You are a helpful support agent. Please make the following response more friendly. Ensure that the reply should be in user language.')
    when 'make_formal'
      GlobalConfigService.load('OPENAI_PROMPT_FORMAL',
                               'You are a helpful support agent. Please make the following response more formal. Ensure that the reply should be in user language.')
    when 'simplify'
      GlobalConfigService.load('OPENAI_PROMPT_SIMPLIFY',
                               'You are a helpful support agent. Please simplify the following response. Ensure that the reply should be in user language.')
    when 'analyze_sentiment'
      GlobalConfigService.load('OPENAI_PROMPT_SENTIMENT_ANALYSIS',
                               'Analyze the following Facebook comment and determine if it contains offensive, inappropriate, or harmful content. Respond with JSON: {"offensive": true/false, "confidence": 0.0-1.0, "reason": "brief explanation"}. Reply in the user\'s language.')
    when 'generate_prompt'
      GlobalConfigService.load('OPENAI_PROMPT_GENERATE_PROMPT',
                               'You are an expert prompt engineer. Based on the user\'s description or context provided, generate a well-structured, effective prompt that can be used for AI interactions. The prompt should be clear, specific, and actionable. Ensure that the generated prompt is in the user\'s language.')
    when 'review_prompt'
      GlobalConfigService.load('OPENAI_PROMPT_REVIEW_PROMPT',
                               'You are an expert prompt reviewer and optimizer. Review the provided prompt and generate an improved, optimized version. The improved prompt should be clearer, more specific, more actionable, and follow best practices for prompt engineering. Maintain the original intent and purpose while enhancing clarity, structure, and effectiveness. Return only the improved prompt without any explanations or comments. Ensure that the improved prompt is in the user\'s language.')
    else
      'You are a helpful support agent. Ensure that the reply should be in user language.'
    end
  end

  def make_api_call(body)
    full_api_url = api_url.end_with?('/chat/completions') ? api_url : "#{api_url}/chat/completions"

    headers = {
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{api_key}"
    }

    Rails.logger.info("OpenAI Global API request to #{full_api_url}: #{body}")
    response = HTTParty.post(full_api_url, headers: headers, body: body)
    Rails.logger.info("OpenAI Global API response: #{response.body}")

    return { error: response.parsed_response, error_code: response.code } unless response.success?

    choices = JSON.parse(response.body)['choices']

    return { message: choices.first['message']['content'] } if choices.present?

    { message: nil }
  end

  def rephrase_message
    make_api_call(build_api_call_body(get_prompt('rephrase')))
  end

  def fix_spelling_grammar_message
    make_api_call(build_api_call_body(get_prompt('fix_spelling_grammar')))
  end

  def shorten_message
    make_api_call(build_api_call_body(get_prompt('shorten')))
  end

  def expand_message
    make_api_call(build_api_call_body(get_prompt('expand')))
  end

  def make_friendly_message
    make_api_call(build_api_call_body(get_prompt('make_friendly')))
  end

  def make_formal_message
    make_api_call(build_api_call_body(get_prompt('make_formal')))
  end

  def simplify_message
    make_api_call(build_api_call_body(get_prompt('simplify')))
  end

  def summarize_message
    return nil unless conversation

    make_api_call(summarize_body)
  end

  def reply_suggestion_message
    return nil unless conversation

    make_api_call(reply_suggestion_body)
  end

  def analyze_sentiment_message
    # Public method to analyze sentiment of a comment
    # Can be called directly without event structure
    result = make_api_call(build_api_call_body(get_prompt('analyze_sentiment'), event['data']['content']))

    # Parse JSON response from OpenAI
    if result[:message].present?
      begin
        parsed = JSON.parse(result[:message])
        {
          offensive: parsed['offensive'] == true,
          confidence: (parsed['confidence'] || 0.0).to_f,
          reason: parsed['reason']
        }
      rescue JSON::ParserError
        # Fallback: try to extract from string
        {
          offensive: result[:message].downcase.include?('"offensive": true') || result[:message].downcase.include?('offensive: true'),
          confidence: 0.5,
          reason: result[:message]
        }
      end
    else
      { offensive: false, confidence: 0.0, reason: 'No response from AI' }
    end
  end

  def generate_prompt_message
    make_api_call(build_api_call_body(get_prompt('generate_prompt')))
  end

  def review_prompt_message
    make_api_call(build_api_call_body(get_prompt('review_prompt')))
  end

  def build_api_call_body(system_content, user_content = event['data']['content'])
    {
      model: gpt_model,
      messages: [
        { role: 'system', content: system_content },
        { role: 'user', content: user_content || '' }
      ]
    }.to_json
  end

  def conversation_messages(in_array_format: false)
    messages = in_array_format ? [] : ''
    character_count = 0

    conversation.messages.where(message_type: [:incoming, :outgoing], private: false)
                .reorder('id desc').each do |message|
      # Skip messages with blank or nil content
      next if message.content.blank?

      # Safety check for content length to prevent nil errors
      content_length = message.content&.length || 0
      break if character_count + content_length > 400_000

      formatted_message = format_message(message, in_array_format)
      if in_array_format
        messages.prepend(formatted_message)
      else
        messages = "#{formatted_message}#{messages}"
      end
      character_count += content_length
    end

    messages
  end

  def format_message(message, in_array_format)
    if in_array_format
      { role: (message.incoming? ? 'user' : 'assistant'), content: message.content || '' }
    else
      sender_type = message.incoming? ? 'Customer' : 'Agent'
      "#{sender_type} #{message.sender&.name} : #{message.content || ''}\n"
    end
  end

  def summarize_body
    system_prompt = get_prompt('summary')

    {
      model: gpt_model,
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: conversation_messages }
      ]
    }.to_json
  end

  def reply_suggestion_body
    system_prompt = get_prompt('reply')

    {
      model: gpt_model,
      messages: [
        { role: 'system', content: system_prompt }
      ].concat(conversation_messages(in_array_format: true))
    }.to_json
  end
end
