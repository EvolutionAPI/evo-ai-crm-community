class AutomationRules::ActionService < ActionService
  # Pipeline + message action implementations live in shared modules so the
  # flow-canvas executor (FlowExecutionService) can reuse the same code
  # without duplication. Behaviour here is unchanged — methods are still
  # private and dispatched via `send` from `perform`.
  include AutomationRules::PipelineActionHandlers
  include AutomationRules::MessageActionHandlers

  def initialize(rule, _account = nil, conversation = nil)
    super(conversation)
    @rule = rule
    Current.executed_by = rule
  end

  def perform
    @rule.actions.each do |action|
      @conversation.reload
      action = action.with_indifferent_access
      begin
        Rails.logger.info "Automation Rule #{@rule.id}: Executing action #{action[:action_name]} with params #{action[:action_params]}"
        send(action[:action_name], action[:action_params])
      rescue StandardError => e
        Rails.logger.error "Automation Rule #{@rule.id}: Error executing action #{action[:action_name]}: #{e.message}"
        EvolutionExceptionTracker.new(e).capture_exception
      end
    end
  ensure
    Current.reset
  end

  private

  def send_attachment(attachment_params)
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

  def send_webhook_event(webhook_url)
    payload = @conversation.webhook_data.merge(event: "automation_event.#{@rule.event_name}")
    clean_url = webhook_url[0].to_s.strip
    WebhookJob.perform_later(clean_url, payload)
  end

  def send_message(message)
    return if conversation_a_tweet?

    params = { content: message[0], private: false, content_attributes: { automation_rule_id: @rule.id } }
    Messages::MessageBuilder.new(nil, @conversation, params).perform
  end

  def send_email_to_team(params)
    teams = Team.where(id: params[0][:team_ids])

    teams.each do |team|
      TeamNotifications::AutomationNotificationMailer.conversation_creation(@conversation, team, params[0][:message])&.deliver_now
    end
  end
end
