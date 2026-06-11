class Messages::MessageBuilder
  include ::FileTypeHelper
  attr_reader :message

  def initialize(user, conversation, params) # rubocop:disable Metrics/CyclomaticComplexity
    @params = params
    @private = params[:private] || false
    @conversation = conversation
    @user = user
    @message_type = params[:message_type] || 'outgoing'
    @attachments = params[:attachments]
    @is_recorded_audio = params[:is_recorded_audio]
    @automation_rule = content_attributes&.dig(:automation_rule_id)
    return unless params.instance_of?(ActionController::Parameters)

    @in_reply_to = content_attributes&.dig(:in_reply_to)
    @is_reaction = content_attributes&.dig(:is_reaction)
    @items = content_attributes&.dig(:items)
  end

  def perform
    @message = @conversation.messages.build(message_params)
    process_template_content if @params[:template_params].present?
    process_emails
    process_attachments
    @message.save!

    @message
  end

  private

  # Extracts content attributes from the given params.
  # - Converts ActionController::Parameters to a regular hash if needed.
  # - Attempts to parse a JSON string if content is a string.
  # - Returns an empty hash if content is not present, if there's a parsing error, or if it's an unexpected type.
  def content_attributes
    params = convert_to_hash(@params)
    content_attributes = params.fetch(:content_attributes, {})

    return parse_json(content_attributes) if content_attributes.is_a?(String)
    return content_attributes if content_attributes.is_a?(Hash)

    {}
  end

  # Converts the given object to a hash.
  # If it's an instance of ActionController::Parameters, converts it to an unsafe hash.
  # Otherwise, returns the object as-is.
  def convert_to_hash(obj)
    return obj.to_unsafe_h if obj.instance_of?(ActionController::Parameters)

    obj
  end

  # Attempts to parse a string as JSON.
  # If successful, returns the parsed hash with symbolized names.
  # If unsuccessful, returns nil.
  def parse_json(content)
    JSON.parse(content, symbolize_names: true)
  rescue JSON::ParserError
    {}
  end

  def process_attachments
    return if @attachments.blank?

    @attachments.each do |uploaded_attachment|
      attachment = @message.attachments.build(
        file: uploaded_attachment
      )
      attachment.meta = process_metadata(uploaded_attachment)
      attachment.file_type = if uploaded_attachment.is_a?(String)
                               file_type_by_signed_id(
                                 uploaded_attachment
                               )
                             else
                               file_type(uploaded_attachment&.content_type)
                             end
    end
  end

  def process_metadata(attachment) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    # NOTE: `is_recorded_audio` can be either a boolean or an array of file names.
    return unless @is_recorded_audio
    return { is_recorded_audio: true } if @is_recorded_audio == true

    return { is_recorded_audio: true } if @is_recorded_audio.is_a?(Array) && attachment.original_filename.in?(@is_recorded_audio)

    # FIXME: Remove backwards compatibility with old format.
    if @is_recorded_audio.is_a?(String)
      parsed = JSON.parse(@is_recorded_audio)
      { is_recorded_audio: true } if parsed.is_a?(Array) && attachment.original_filename.in?(parsed)
    end
  rescue JSON::ParserError
    nil
  end

  def process_emails
    return unless @conversation.inbox&.inbox_type == 'Email'

    cc_emails = process_email_string(@params[:cc_emails])
    bcc_emails = process_email_string(@params[:bcc_emails])
    to_emails = process_email_string(@params[:to_emails])

    all_email_addresses = cc_emails + bcc_emails + to_emails
    validate_email_addresses(all_email_addresses)

    @message.content_attributes[:cc_emails] = cc_emails
    @message.content_attributes[:bcc_emails] = bcc_emails
    @message.content_attributes[:to_emails] = to_emails
  end

  def process_email_string(email_string)
    return [] if email_string.blank?

    email_string.gsub(/\s+/, '').split(',')
  end

  def validate_email_addresses(all_emails)
    all_emails&.each do |email|
      raise StandardError, 'Invalid email address' unless email.match?(URI::MailTo::EMAIL_REGEXP)
    end
  end

  def message_type
    if @conversation.inbox.channel_type != 'Channel::Api' && @message_type == 'incoming'
      raise StandardError, 'Incoming messages are only allowed in Api inboxes'
    end

    @message_type
  end

  def sender
    message_type == 'outgoing' ? (message_sender || @user) : @conversation.contact
  end

  def external_created_at
    @params[:external_created_at].present? ? { external_created_at: @params[:external_created_at] } : {}
  end

  def automation_rule_id
    @automation_rule.present? ? { content_attributes: { automation_rule_id: @automation_rule } } : {}
  end

  def campaign_id
    @params[:campaign_id].present? ? { additional_attributes: { campaign_id: @params[:campaign_id] } } : {}
  end

  # Stores the envelope AS RECEIVED on purpose: for journey/API callers that
  # means unresolved {{root.path}} strings (config provenance), while the
  # automation executors hand in pre-resolved values. Do not "normalize".
  def template_params_for_additional_attributes
    return {} unless @params[:template_params].present?

    params_hash = @params[:template_params].is_a?(Hash) ? @params[:template_params] : JSON.parse(@params[:template_params].to_json)
    { additional_attributes: { template_params: params_hash } }
  end

  def process_template_content
    return unless @params[:template_params].present?

    template_info = @params[:template_params].is_a?(Hash) ? @params[:template_params] : JSON.parse(@params[:template_params].to_json)
    template_id = template_info['id'] || @params[:message_template_id]
    # Allow id-only payloads: the canonical key is the id, name is the fallback.
    return unless template_info['name'].present? || template_id.present?

    # Allowlist gate (B1, EVO-1267): resolve template variables through the
    # default-deny resolver BEFORE the channel branch, so no inbox/channel
    # credential path can be traversed into the rendered content.
    template_info = resolve_template_variables(template_info)

    Rails.logger.info "Processing template: id=#{template_id}, name=#{template_info['name']}, language=#{template_info['language']}, inbox_type=#{@conversation.inbox&.inbox_type}"

    # Resolve id-first (global-aware), falling back to name + language.
    template = MessageTemplates::SendResolver.new(
      id: template_id,
      name: template_info['name'],
      language: template_info['language'],
      channel: @conversation.inbox&.channel
    ).resolve

    unless template
      Rails.logger.error "Template not found: id=#{template_id}, name=#{template_info['name']}, language=#{template_info['language'] || 'pt_BR'}, channel_id=#{@conversation.inbox.channel&.id}"
      return
    end

    Rails.logger.info "Template found: #{template.name} (#{template.id}), metadata keys: #{template.metadata&.keys&.inspect}"

    persist_resolved_template_id(template)

    # Process template based on channel type
    if @conversation.inbox&.inbox_type == 'Email'
      process_email_template(template, template_info)
    else
      # For WhatsApp and other channels, use existing render_with_variables
      render_template_content(template, template_info['processed_params'] || {})
    end
  end

  # Records the resolved template id on the message even when the caller located
  # the template by name, so downstream consumers can reference
  # message_template_id (EVO-1235).
  def persist_resolved_template_id(template)
    attrs = @message.additional_attributes || {}
    template_params = (attrs['template_params'] || attrs[:template_params] || {}).dup
    template_params['id'] = template.id
    # name is required by Message::TEMPLATE_PARAMS_SCHEMA; backfill it for id-only payloads.
    template_params['name'] ||= template.name
    attrs['template_params'] = template_params
    @message.additional_attributes = attrs
  end

  def render_template_content(template, processed_params)
    @message.content = template.render_with_variables(processed_params)
  rescue ArgumentError => e
    # A required variable resolved blank with no fallback. Keep the
    # caller-rendered content instead of failing the send (EVO-1267 AC4).
    Rails.logger.error "Template #{template.name}: variable rendering failed (#{e.message}); keeping incoming content"
  end

  # EVO-1267: journey/API callers may send {{contact.x}} / {{conversation.x}} /
  # {{pipeline.x}} paths as variable values; resolve them against this
  # conversation before rendering. Automation Rules executors pre-resolve and
  # mark the envelope, so their (possibly user-originated) values are never
  # re-expanded here.
  def resolve_template_variables(template_info)
    processed_params = template_info['processed_params']
    return template_info if template_info['variables_resolved'] || !processed_params.is_a?(Hash)

    template_info.merge(
      'processed_params' => TemplateVariableResolver.new(@conversation)
                                                    .resolve_params(processed_params, template_info['variable_fallbacks'])
    )
  end

  def process_email_template(template, template_info)
    # For email templates, prioritize HTML from metadata.html_content
    html_content = nil

    # Priority 1: Use HTML from metadata.html_content (new format)
    # JSONB can be accessed with string or symbol keys
    metadata = template.metadata || {}
    html_content = metadata['html_content'] || metadata[:html_content] if metadata.present?

    Rails.logger.info "Template #{template.name}: html_content from metadata: #{html_content.present? ? 'found' : 'not found'}"

    # Priority 2: Check if content is HTML (legacy format)
    if html_content.blank? && template.content.present?
      content = template.content.strip
      # Check if content is JSON (react-email-editor design format)
      is_json = (content.start_with?('{', '[')) &&
                (content.include?('"counters"') || content.include?('"body"') || content.include?('"schemaVersion"'))

      if is_json
        Rails.logger.warn "Template #{template.name}: content is JSON design format, but no HTML in metadata. Template needs to be re-saved."
      else
        # Content is HTML (legacy format)
        html_content = content
        Rails.logger.info "Template #{template.name}: using legacy HTML from content field"
      end
    end

    # If we have HTML content, process variables and set it
    if html_content.present?
      processed_params = template_info['processed_params'] || {}
      processed_html = html_content.dup

      # Replace template variables with actual values
      processed_params.each do |key, value|
        processed_html = processed_html.gsub("{{#{key}}}", value.to_s) if value.present?
      end

      @message.content = processed_html
      # Set content_type to text for email HTML (backend will handle rendering)
      @message.content_type = :text unless @message.content_type.present?

      # Extract and set email subject from template settings if available
      template_settings = template.settings || {}
      template_subject = template_settings['subject'] || template_settings[:subject]

      if template_subject.present?
        # Process subject variables if any
        processed_subject = template_subject.dup
        processed_params.each do |key, value|
          processed_subject = processed_subject.gsub("{{#{key}}}", value.to_s) if value.present?
        end

        # Set subject in conversation additional_attributes for email mailer to use
        @conversation.additional_attributes ||= {}
        @conversation.additional_attributes['mail_subject'] = processed_subject
        @conversation.save(validate: false) # Save without validation to avoid triggering callbacks
        Rails.logger.info "Email template #{template.name}: subject set to '#{processed_subject}'"
      end

      Rails.logger.info "Email template #{template.name} processed: HTML content set (#{processed_html.length} chars)"
    else
      # No HTML found - template has JSON but no HTML
      Rails.logger.error "Email template #{template.name} has no HTML content. Template metadata keys: #{metadata.keys.inspect}, Content is JSON: #{template.content&.start_with?('{')}"
      # Use a placeholder message instead of sending JSON
      @message.content = "<p>Template de email '#{template.name}' precisa ser editado e salvo novamente no editor visual.</p>"
    end
  end

  def message_sender
    return if @params[:sender_type] != 'AgentBot'

    AgentBot.find_by(id: @params[:sender_id])
  end

  def message_params
    # If using template, content will be set by process_template_content
    # Otherwise, use the content from params
    content_value = @params[:content] || ''

    {
      inbox_id: @conversation.inbox_id,
      message_type: message_type,
      content: content_value,
      private: @private,
      sender: sender,
      content_type: @params[:content_type],
      items: @items,
      in_reply_to: @in_reply_to,
      is_reaction: @is_reaction,
      echo_id: @params[:echo_id],
      source_id: @params[:source_id]
    }.merge(external_created_at).merge(automation_rule_id).merge(campaign_id).merge(template_params_for_additional_attributes)
  end
end
