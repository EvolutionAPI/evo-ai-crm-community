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
      unless canned
        log_canned_response_not_found(canned_id)
        return
      end

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

    def log_canned_response_not_found(canned_id)
      Rails.logger.warn "Automation Rule #{@rule.id}: Canned response #{canned_id.inspect} not found; skipping send_canned_response for conversation #{@conversation.id}"
    end

    def send_template(params)
      return if conversation_a_tweet?
      return if params.blank?

      template_params = params[0].is_a?(Hash) ? params[0].deep_stringify_keys : nil
      # Accept an id-only payload (EVO-1235): the id is the canonical key, name is
      # only the legacy fallback.
      return if template_params.blank? || template_action_target_missing?(template_params)

      message_params = {
        content: '',
        private: false,
        message_type: 'outgoing',
        template_params: resolve_template_params(normalize_template_id(template_params)),
        content_attributes: { automation_rule_id: @rule.id }
      }

      Messages::MessageBuilder.new(nil, @conversation, message_params).perform
    end

    # True when an automation template action carries no usable target — neither a
    # name (legacy) nor an id (canonical, EVO-1235).
    def template_action_target_missing?(template_params)
      template_params['name'].blank? && template_params['template_id'].blank? && template_params['id'].blank?
    end

    # Maps the legacy `template_id` key onto `id` (what MessageBuilder/SendResolver
    # read) so automations resolve templates by id, global-aware (EVO-1235).
    def normalize_template_id(template_params)
      id = template_params['id'] || template_params['template_id']
      normalized = template_params.except('template_id')
      normalized['id'] = id if id.present?
      normalized
    end

    # Resolution lives in TemplateVariableResolver (shared with
    # Messages::MessageBuilder — EVO-1267). The variables_resolved flag stops
    # the builder from running a second pass over values that may now contain
    # user-originated text (a contact named "{{contact.email}}" must not
    # re-expand downstream).
    def resolve_template_params(template_params)
      processed_params = template_params['processed_params']
      return template_params unless processed_params.is_a?(Hash)

      template_params.merge(
        'processed_params' => TemplateVariableResolver.new(@conversation).resolve_params(processed_params),
        'variables_resolved' => true
      )
    end
  end
end
