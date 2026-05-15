# frozen_string_literal: true

class Widget::PreChatFormValidator
  class ValidationError < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super(errors.values.flatten.join(', '))
    end
  end

  def initialize(web_widget:, contact_params:, message_content:, custom_attributes: {}, has_active_campaign: false)
    @web_widget = web_widget
    @contact_params = normalize_params(contact_params)
    @message_content = message_content
    @custom_attributes = normalize_params(custom_attributes)
    @has_active_campaign = has_active_campaign
    @errors = {}
  end

  def perform
    return { valid: true, sanitized_data: {} } unless @web_widget.pre_chat_form_enabled?

    validate_required_fields
    validate_email_format
    validate_phone_format
    sanitize_inputs

    raise ValidationError, @errors if @errors.any?

    {
      valid: true,
      sanitized_data: {
        contact_params: @contact_params,
        message_content: @message_content,
        custom_attributes: @custom_attributes
      }
    }
  end

  private

  def pre_chat_fields
    @pre_chat_fields ||= begin
      pre_chat_options = (@web_widget.pre_chat_form_options || {}).with_indifferent_access
      Array(pre_chat_options['pre_chat_fields'])
    end
  end

  def validate_required_fields
    pre_chat_fields.each do |field|
      field_name = field['name']
      field_required = field['required'] == true || field['required'] == 'true'
      next unless field_required

      value = get_field_value(field_name, field)
      
      if value.blank?
        add_error(field_name, I18n.t('widget.pre_chat_form.field_required', field: field['label'] || field_name))
      else
        # Validate regex pattern if provided
        validate_field_pattern(field_name, field, value)
      end
    end

    # Validate message if required (when no active campaign)
    if message_required? && @message_content.blank?
      add_error(:message, I18n.t('widget.pre_chat_form.message_required'))
    end
  end

  def validate_field_pattern(field_name, field, value)
    return if value.blank?
    return unless field['regex_pattern'].present?

    regex_pattern = field['regex_pattern']
    regex_cue = field['regex_cue'] || I18n.t('widget.pre_chat_form.invalid_format')

    begin
      regex = Regexp.new(regex_pattern)
      unless regex.match?(value.to_s)
        add_error(field_name, regex_cue)
      end
    rescue RegexpError => e
      Rails.logger.error "Invalid regex pattern in pre-chat field #{field_name}: #{e.message}"
      # Don't fail validation if regex is invalid, just log it
    end
  end

  def validate_email_format
    email = @contact_params[:email] || @contact_params['email']
    return if email.blank?

    unless valid_email?(email)
      add_error(:email, I18n.t('widget.pre_chat_form.invalid_email'))
    end
  end

  def validate_phone_format
    phone = @contact_params[:phone_number] || @contact_params['phone_number']
    return if phone.blank?

    unless valid_phone?(phone)
      add_error(:phone_number, I18n.t('widget.pre_chat_form.invalid_phone'))
    end
  end

  def sanitize_inputs
    # Sanitize contact name
    if @contact_params[:name].present?
      @contact_params[:name] = sanitize_string(@contact_params[:name])
    end

    # Sanitize message content
    if @message_content.present?
      @message_content = sanitize_string(@message_content)
    end

    # Sanitize custom attributes
    @custom_attributes.each do |key, value|
      if value.is_a?(String)
        @custom_attributes[key] = sanitize_string(value)
      elsif value.is_a?(Hash)
        @custom_attributes[key] = sanitize_hash(value)
      end
    end
  end

  def get_field_value(field_name, field)
    case field_name
    when 'emailAddress', 'email'
      @contact_params[:email] || @contact_params['email']
    when 'fullName', 'name'
      @contact_params[:name] || @contact_params['name']
    when 'phoneNumber', 'phone_number'
      @contact_params[:phone_number] || @contact_params['phone_number']
    when 'message'
      @message_content
    else
      # Check custom attributes
      field_type = field['field_type']
      if field_type == 'conversation_attribute' || field_type == 'contact_attribute'
        @custom_attributes[field_name] || @custom_attributes[field_name.to_sym]
      else
        @custom_attributes[field_name] || @custom_attributes[field_name.to_sym]
      end
    end
  end

  def message_required?
    # Message is required when there's no active campaign
    # This logic should match the frontend validation
    !@has_active_campaign
  end

  def valid_email?(email)
    return false if email.blank?

    # Basic email validation
    email_regex = /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
    email_regex.match?(email.to_s.strip)
  end

  def valid_phone?(phone)
    return false if phone.blank?

    # Remove spaces and dashes
    cleaned_phone = phone.to_s.gsub(/[\s\-]/, '')
    
    # International format: + followed by 1-15 digits
    # Examples: +5511999999999, +1234567890
    phone_regex = /\A\+[1-9]\d{1,14}\z/
    phone_regex.match?(cleaned_phone)
  end

  def sanitize_string(str)
    return str unless str.is_a?(String)

    # Remove HTML tags and script content to prevent XSS attacks
    # Rails' sanitize removes potentially dangerous HTML/JavaScript while preserving text content
    sanitized = ActionController::Base.helpers.sanitize(str, tags: [])
    
    # Additional safety: remove any remaining script-like patterns
    # This catches edge cases where sanitize might miss something
    # Remove script tags and their content (including multiline)
    sanitized = sanitized.gsub(/<script[^>]*>.*?<\/script>/mi, '')
                         .gsub(/javascript:/i, '')
                         .gsub(/on\w+\s*=/i, '')
    
    # Remove common XSS patterns that might remain after sanitize
    # Remove alert, eval, and other dangerous function calls
    sanitized = sanitized.gsub(/alert\s*\(/i, '')
                         .gsub(/eval\s*\(/i, '')
                         .gsub(/document\.(cookie|write|writeln)/i, '')
    
    sanitized
  end

  def sanitize_hash(hash)
    hash.each_with_object({}) do |(key, value), sanitized|
      if value.is_a?(String)
        sanitized[key] = sanitize_string(value)
      elsif value.is_a?(Hash)
        sanitized[key] = sanitize_hash(value)
      elsif value.is_a?(Array)
        sanitized[key] = value.map { |v| v.is_a?(String) ? sanitize_string(v) : v }
      else
        sanitized[key] = value
      end
    end
  end

  def add_error(field, message)
    @errors[field] ||= []
    @errors[field] << message unless @errors[field].include?(message)
  end

  def normalize_params(obj)
    hash = obj.respond_to?(:to_unsafe_h) ? obj.to_unsafe_h : obj.to_h
    hash.with_indifferent_access
  end
end
