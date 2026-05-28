module AutomationRules
  # Shared message action handlers consumed by both the modal-style
  # AutomationRules::ActionService and the flow-canvas-style
  # AutomationRules::FlowExecutionService. Single source of truth for the
  # canned-response action and the template-with-variables action so both
  # executor surfaces stay in lockstep — see app/services/automation_rules/README.md.
  #
  # Required instance state on the including class:
  #   @rule         — AutomationRule (logging + audit attribution)
  #   @conversation — Conversation (target of message dispatch)
  #
  # Also required: `conversation_a_tweet?` predicate to gate tweet-flavoured
  # conversations (ActionService inherits it from its parent; FlowExecutionService
  # defines its own copy — pure conversation predicate, no shared state).
  #
  # All methods are private when included.
  module MessageActionHandlers
    private

    def send_canned_response(params)
      return if conversation_a_tweet?
      return if params.blank?

      canned_id = params[0].is_a?(Hash) ? (params[0][:canned_response_id] || params[0]['canned_response_id']) : params[0]
      canned = CannedResponse.find_by(id: canned_id)
      return unless canned

      message_params = {
        content: canned.content,
        private: false,
        content_attributes: { automation_rule_id: @rule.id }
      }

      if canned.attachments.any?
        blobs = canned.attachments.map(&:file).select(&:attached?).map(&:blob)
        message_params[:attachments] = blobs if blobs.any?
      end

      Messages::MessageBuilder.new(nil, @conversation, message_params).perform
    end

    def send_template(params)
      return if conversation_a_tweet?
      return if params.blank?

      template_params = params[0].is_a?(Hash) ? params[0].deep_stringify_keys : nil
      return if template_params.blank? || template_params['name'].blank?

      message_params = {
        content: '',
        private: false,
        message_type: 'outgoing',
        template_params: resolve_template_params(template_params.except('template_id')),
        content_attributes: { automation_rule_id: @rule.id }
      }

      Messages::MessageBuilder.new(nil, @conversation, message_params).perform
    end

    def resolve_template_params(template_params)
      processed_params = template_params['processed_params']
      return template_params unless processed_params.is_a?(Hash)

      template_params.merge(
        'processed_params' => processed_params.transform_values { |value| resolve_template_value(value) }
      )
    end

    def resolve_template_value(value)
      return value unless value.is_a?(String)

      value.gsub(/\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}/) do
        resolved = resolve_template_path(Regexp.last_match(1))
        resolved.nil? ? '' : resolved.to_s
      end
    end

    def resolve_template_path(path)
      root, *segments = path.split('.')
      source = case root
               when 'contact'
                 @conversation.contact
               when 'conversation'
                 @conversation
               else
                 return nil
               end

      segments.reduce(source) do |current, segment|
        return nil if current.blank?

        if current.respond_to?(segment)
          current.public_send(segment)
        elsif current.respond_to?(:[])
          current[segment] || current[segment.to_sym]
        end
      end
    end
  end
end
