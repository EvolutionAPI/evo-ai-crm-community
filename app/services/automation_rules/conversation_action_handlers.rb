module AutomationRules
  # Single source of truth for the conversation-bound automation
  # actions that used to be duplicated between the modal executor
  # (`ActionService` / `AutomationRules::ActionService`) and the flow-canvas
  # executor (`AutomationRules::FlowExecutionService`). Both surfaces had
  # silently diverged (change-status no-op, stub transcript, missing inbox
  # guard on assign_agent, divergent webhook event strings); centralising the
  # implementations here makes that class of divergence structurally
  # impossible. See app/services/automation_rules/README.md.
  #
  # Included by:
  #   - `ActionService`                (base; also reaches Macros::ExecutionService)
  #   - `AutomationRules::ActionService` (via the base class)
  #   - `AutomationRules::FlowExecutionService`
  #
  # Required instance state on the including class:
  #   @conversation — Conversation, or nil for contact-triggered flows.
  #   @contact      — Contact (only the flow executor sets this; optional).
  #   @rule         — AutomationRule. Required by the message/attachment/webhook
  #                   actions (audit attribution + attached files). The base
  #                   `ActionService` lineage that does not set @rule (Macros)
  #                   never dispatches those actions through this module.
  #
  # All methods are private when included; callers reach them via `send`
  # (modal/canvas dispatch) or `super` (Macros overrides).
  module ConversationActionHandlers
    include EmailHelper

    # Automation rules persist label_ids (UUIDs) in `action_params`, but
    # `acts_as_taggable_on :labels` stores tags by their **title**. Translate
    # UUIDs to titles; values that aren't UUIDs (legacy rules that already
    # stored titles) are kept as-is so older configurations keep working.
    UUID_LABEL_REGEX = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    private

    # --- Status / priority -------------------------------------------------

    def change_status(status)
      return unless @conversation

      @conversation.update!(status: status[0])
    end

    def change_priority(priority)
      return unless @conversation

      @conversation.update!(priority: (priority[0] == 'nil' ? nil : priority[0]))
    end

    def mute_conversation(_params = nil)
      return unless @conversation

      @conversation.mute!
    end

    def snooze_conversation(_params = nil)
      return unless @conversation

      @conversation.snoozed!
    end

    def resolve_conversation(_params = nil)
      return unless @conversation

      @conversation.resolved!
    end

    # --- Assignment --------------------------------------------------------

    def assign_agent(agent_ids = [])
      return unless @conversation
      return @conversation.update!(assignee_id: nil) if agent_ids[0] == 'nil'

      return unless agent_belongs_to_inbox?(agent_ids)

      @agent = User.find_by(id: agent_ids)
      @conversation.update!(assignee_id: @agent.id) if @agent.present?
    end

    def assign_team(team_ids = [])
      return unless @conversation

      # FIXME: The explicit checks for zero or nil (string) is bad. Move this
      # to a separate unassign action.
      should_unassign = team_ids.blank? || %w[nil 0].include?(team_ids[0].to_s)
      return @conversation.update!(team_id: nil) if should_unassign

      # check if team belongs to account only if team_id is present; if nil it
      # means the team is being unassigned.
      return unless !team_ids[0].nil? && team_belongs_to_account?(team_ids)

      @conversation.update!(team_id: team_ids[0])
    end

    # --- Labels (conversation OR contact) ----------------------------------

    def add_label(labels)
      return if Array(labels).empty?

      if @conversation
        @conversation.reload.add_labels(resolve_label_titles(labels))
      elsif @contact
        # Ensure Current.executed_by is set to prevent loop, and route through
        # the setter so `saved_change_to_label_list?` dirty-tracks the change
        # and Contact#publish_label_changes fires.
        Current.executed_by = @rule
        titles = Label.where(id: labels).pluck(:title)
        @contact.update!(label_list: (@contact.label_list + titles).uniq)
      end
    end

    def remove_label(labels)
      return if Array(labels).empty?

      if @conversation
        targets = resolve_label_titles(labels)
        @conversation.update!(label_list: @conversation.label_list - targets)
      elsif @contact
        Current.executed_by = @rule
        titles = Label.where(id: labels).pluck(:title)
        @contact.update!(label_list: @contact.label_list - titles)
      end
    end

    # --- Custom attributes -------------------------------------------------

    # EVO-1751: set/update a custom attribute value from an automation action.
    # Routes by the definition's attribute_model so a single action covers
    # conversation, contact and pipeline-item custom attributes. The value is
    # stored verbatim in the JSONB column (string contract); type casting is
    # done at read/query time, consistent with the rest of the custom-attribute
    # code. attribute_key is only unique per attribute_model, so the params
    # carry the model to disambiguate the lookup and the write target.
    def update_custom_attribute(params)
      raw = Array(params).first
      return unless raw.is_a?(Hash)

      param = raw.with_indifferent_access
      key = param[:custom_attribute_key].to_s
      model = param[:custom_attribute_model].to_s
      return if key.blank? || model.blank?

      definition = CustomAttributeDefinition.find_by(attribute_key: key, attribute_model: model)
      return unless definition

      value = cast_custom_attribute_value(definition, param[:custom_attribute_value])
      apply_custom_attribute(model, key, value)
    end

    # The wire value is a string; checkbox attributes must be stored as a real
    # boolean so the canonical read path (Boolean(raw)) matches — "false" stored
    # as a string would otherwise read back as truthy. Other display types stay
    # verbatim (cast at read/query time, as the rest of the custom-attribute code).
    def cast_custom_attribute_value(definition, value)
      return value unless definition.attribute_display_type == 'checkbox'

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def apply_custom_attribute(model, key, value)
      case model
      when 'conversation_attribute' then set_conversation_custom_attribute(key, value)
      when 'contact_attribute' then set_contact_custom_attribute(key, value)
      when 'pipeline_item_attribute' then set_pipeline_item_custom_field(key, value)
      end
    end

    def set_conversation_custom_attribute(key, value)
      return unless @conversation

      attributes = (@conversation.custom_attributes || {}).merge(key => value)
      @conversation.update!(custom_attributes: attributes)
    end

    def set_contact_custom_attribute(key, value)
      contact = @contact || @conversation&.contact
      return unless contact

      Current.executed_by = @rule
      attributes = (contact.custom_attributes || {}).merge(key => value)
      contact.update!(custom_attributes: attributes)
    end

    def set_pipeline_item_custom_field(key, value)
      return unless @conversation

      pipeline_item = @conversation.pipeline_items.first
      return unless pipeline_item

      fields = (pipeline_item.custom_fields || {}).merge(key => value)
      pipeline_item.update!(custom_fields: fields)
    end

    # --- Messaging ---------------------------------------------------------

    def send_message(message)
      return unless @conversation
      return if conversation_a_tweet?

      params = { content: message[0], private: false, content_attributes: { automation_rule_id: @rule.id } }
      Messages::MessageBuilder.new(nil, @conversation, params).perform
    end

    def send_attachment(attachment_params)
      return unless @conversation
      return if conversation_a_tweet?

      if attachment_params.is_a?(Array)
        blob_ids = attachment_params
        inbox_id = nil
      elsif attachment_params.is_a?(Hash)
        blob_ids = attachment_params[:attachment_ids] || attachment_params['attachment_ids']
        inbox_id = attachment_params[:inbox_id] || attachment_params['inbox_id']
      else
        blob_ids = [attachment_params].flatten
        inbox_id = nil
      end

      return unless @rule.files.attached?

      blobs = ActiveStorage::Blob.where(id: blob_ids)
      return if blobs.blank?

      params = { content: nil, private: false, attachments: blobs }

      if inbox_id
        inbox = Inbox.find_by(id: inbox_id)
        if inbox && @conversation.inbox != inbox
          Rails.logger.warn "Automation Rule #{@rule.id}: Inbox mismatch. Conversation inbox: #{@conversation.inbox.id}, Requested inbox: #{inbox_id}"
        end
      end

      Messages::MessageBuilder.new(nil, @conversation, params).perform
    rescue StandardError => e
      Rails.logger.error "Automation Rule #{@rule.id}: Error sending attachment: #{e.message}"
      raise e
    end

    # --- Email -------------------------------------------------------------

    def send_email_to_team(params)
      return unless @conversation

      teams = Team.where(id: params[0][:team_ids])
      teams.each do |team|
        TeamNotifications::AutomationNotificationMailer.conversation_creation(@conversation, team, params[0][:message])&.deliver_now
      end
    end

    def send_email_transcript(emails)
      return unless @conversation

      emails = emails[0].gsub(/\s+/, '').split(',')
      emails.each do |email|
        email = parse_email_variables(@conversation, email)
        ConversationReplyMailer.with(account: nil).conversation_transcript(@conversation, email)&.deliver_later
      end
    end

    # --- Webhook -----------------------------------------------------------

    # Unified canonical event string across the simple, flow and
    # contact executors. The trigger identity is carried by `@rule.event_name`
    # (e.g. conversation_updated, contact_created). Verify no downstream
    # consumer filters on the legacy `automation_flow.*` / bare `contact_*`
    # prefixes before relying on this contract.
    def send_webhook_event(webhook_url)
      payload_data = @conversation ? @conversation.webhook_data : (@contact&.webhook_data || {})
      payload = payload_data.merge(event: "automation_event.#{@rule.event_name}")

      clean_url = webhook_url[0].to_s.strip
      WebhookJob.perform_later(clean_url, payload)
    end

    # --- Helpers -----------------------------------------------------------

    def agent_belongs_to_inbox?(agent_ids)
      member_ids = @conversation.inbox.members.pluck(:user_id)
      assignable_agent_ids = member_ids + User.where(type: 'SuperAdmin').pluck(:id)

      assignable_agent_ids.include?(agent_ids[0])
    end

    def team_belongs_to_account?(team_ids)
      Team.exists?(id: team_ids[0])
    end

    def conversation_a_tweet?
      @conversation&.additional_attributes&.dig('type') == 'tweet'
    end

    def resolve_label_titles(values)
      values = Array(values).map(&:to_s).reject(&:empty?)
      return [] if values.empty?

      uuids, others = values.partition { |v| UUID_LABEL_REGEX.match?(v) }
      return others if uuids.empty?

      titles_by_id = Label.where(id: uuids).pluck(:id, :title).to_h.transform_keys(&:to_s)
      resolved     = uuids.filter_map { |id| titles_by_id[id] }

      (others + resolved).uniq
    end
  end
end
