class Integrations::OpenaiBaseService
  # gpt-4.1-nano supports 128,000 tokens
  # 1 token is approx 4 characters
  # sticking with 120000 to be safe
  # 120000 * 4 = 480,000 characters (rounding off downwards to 400,000 to be safe)
  TOKEN_LIMIT = 400_000

  ALLOWED_EVENT_NAMES = %w[rephrase summarize reply_suggestion fix_spelling_grammar shorten expand make_friendly make_formal simplify generate_prompt review_prompt].freeze
  CACHEABLE_EVENTS = %w[].freeze

  pattr_initialize [:hook!, :event!]

  def perform
    return nil unless valid_event_name?

    return value_from_cache if value_from_cache.present?

    response = send("#{event_name}_message")
    save_to_cache(response) if response.present?

    response
  end

  private

  def event_name
    event['name']
  end

  def cache_key
    return nil unless event_is_cacheable?

    return nil unless conversation

    # since the value from cache depends on the conversation last_activity_at, it will always be fresh
    format(::Redis::Alfred::OPENAI_CONVERSATION_KEY, event_name: event_name, conversation_id: conversation.id,
                                                     updated_at: conversation.last_activity_at.to_i)
  end

  def value_from_cache
    return nil unless event_is_cacheable?
    return nil if cache_key.blank?

    deserialize_cached_value(Redis::Alfred.get(cache_key))
  end

  def deserialize_cached_value(value)
    return nil if value.blank?

    JSON.parse(value, symbolize_names: true)
  rescue JSON::ParserError
    # If json parse failed, returning the value as is will fail too
    # since we access the keys as symbols down the line
    # So it's best to return nil
    nil
  end

  def save_to_cache(response)
    return nil unless event_is_cacheable?

    # Serialize to JSON
    # This makes parsing easy when response is a hash
    Redis::Alfred.setex(cache_key, response.to_json)
  end

  def conversation
    conversation_id = event.dig('data', 'conversation_display_id')
    return nil if conversation_id.blank?

    @conversation ||= Conversation.find_by(id: conversation_id) ||
                      Conversation.find_by(display_id: conversation_id)
  end

  def valid_event_name?
    # self.class::ALLOWED_EVENT_NAMES is way to access ALLOWED_EVENT_NAMES defined in the class hierarchy of the current object.
    # This ensures that if ALLOWED_EVENT_NAMES is updated elsewhere in it's ancestors, we access the latest value.
    self.class::ALLOWED_EVENT_NAMES.include?(event_name)
  end

  def event_is_cacheable?
    # self.class::CACHEABLE_EVENTS is way to access CACHEABLE_EVENTS defined in the class hierarchy of the current object.
    # This ensures that if CACHEABLE_EVENTS is updated elsewhere in it's ancestors, we access the latest value.
    self.class::CACHEABLE_EVENTS.include?(event_name)
  end

  # Get OpenAI API URL from global configuration
  def api_url
    @api_url ||= "#{GlobalConfigService.load('OPENAI_API_URL', 'https://api.openai.com/v1')}/chat/completions"
  end

  # Get OpenAI model from global configuration
  def gpt_model
    @gpt_model ||= GlobalConfigService.load('OPENAI_MODEL', 'gpt-4.1-nano')
  end

  # Get API key from global configuration or hook settings (fallback)
  # The registry is the single source. The old precedence (global config wins,
  # account hook is the fallback) did not disappear — it dropped one level and
  # now lives as the last link inside Ai::CredentialResolver, so nothing breaks
  # before the migration and no consumer carries precedence logic of its own.
  def api_key
    Ai::CredentialResolver.resolve_key(for_consumer: :inbox_assist, legacy_hook: hook)
  end

  # Get dynamic prompts from global configuration
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
    current_api_key = api_key

    if current_api_key.blank?
      Rails.logger.error('OpenAI API key not configured. Please configure it in Admin settings.')
      return { error: 'OpenAI API key not configured', error_code: 401 }
    end

    headers = {
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{current_api_key}"
    }

    Rails.logger.info("OpenAI API request to #{api_url}: #{body}")
    response = HTTParty.post(api_url, headers: headers, body: body)
    Rails.logger.info("OpenAI API response: #{response.body}")

    return { error: response.parsed_response, error_code: response.code } unless response.success?

    choices = JSON.parse(response.body)['choices']

    return { message: choices.first['message']['content'] } if choices.present?

    { message: nil }
  end
end
