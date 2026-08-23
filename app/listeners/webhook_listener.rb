class WebhookListener < BaseListener
  def conversation_status_changed(event)
    conversation = extract_conversation_and_account(event)[0]
    changed_attributes = extract_changed_attributes(event)
    inbox = conversation.inbox
    payload = conversation.webhook_data.merge(event: __method__.to_s, changed_attributes: changed_attributes)
    deliver_webhook_payloads(payload, inbox)
  end

  def conversation_updated(event)
    conversation = extract_conversation_and_account(event)[0]
    changed_attributes = extract_changed_attributes(event)
    inbox = conversation.inbox
    payload = conversation.webhook_data.merge(event: __method__.to_s, changed_attributes: changed_attributes)
    deliver_webhook_payloads(payload, inbox)
  end

  def conversation_created(event)
    conversation = extract_conversation_and_account(event)[0]
    inbox = conversation.inbox
    payload = conversation.webhook_data.merge(event: __method__.to_s)
    deliver_webhook_payloads(payload, inbox)
  end

  def message_created(event)
    message = extract_message_and_account(event)[0]
    inbox = message.inbox

    return unless message.webhook_sendable?

    payload = message.webhook_data.merge(event: __method__.to_s)
    deliver_webhook_payloads(payload, inbox)
  end

  def message_updated(event)
    message = extract_message_and_account(event)[0]
    inbox = message.inbox

    return unless message.webhook_sendable?

    payload = message.webhook_data.merge(event: __method__.to_s)
    deliver_webhook_payloads(payload, inbox)
  end

  def webwidget_triggered(event)
    contact_inbox = event.data[:contact_inbox]
    inbox = contact_inbox.inbox

    payload = contact_inbox.webhook_data.merge(event: __method__.to_s)
    payload[:event_info] = event.data[:event_info]
    deliver_webhook_payloads(payload, inbox)
  end

  def contact_created(event)
    contact, account = extract_contact_and_account(event)
    payload = contact.webhook_data.merge(event: __method__.to_s)
    deliver_account_webhooks(payload, account)
  end

  def contact_updated(event)
    contact, account = extract_contact_and_account(event)
    changed_attributes = extract_changed_attributes(event)
    return if changed_attributes.blank?

    payload = contact.webhook_data.merge(event: __method__.to_s, changed_attributes: changed_attributes)
    deliver_account_webhooks(payload, account)
  end

  def inbox_created(event)
    inbox, account = extract_inbox_and_account(event)
    inbox_webhook_data = Inbox::EventDataPresenter.new(inbox).push_data
    payload = inbox_webhook_data.merge(event: __method__.to_s)
    deliver_account_webhooks(payload, account)
  end

  def inbox_updated(event)
    inbox, account = extract_inbox_and_account(event)
    changed_attributes = extract_changed_attributes(event)
    return if changed_attributes.blank?

    inbox_webhook_data = Inbox::EventDataPresenter.new(inbox).push_data
    payload = inbox_webhook_data.merge(event: __method__.to_s, changed_attributes: changed_attributes)
    deliver_account_webhooks(payload, account)
  end

  def conversation_typing_on(event)
    handle_typing_status(__method__.to_s, event)
  end

  def conversation_typing_off(event)
    handle_typing_status(__method__.to_s, event)
  end

  def pipeline_item_created(event)
    pipeline_item = event.data[:pipeline_item]
    account = single_tenant_account
    payload = pipeline_item.webhook_data.merge(event: 'pipeline_item.created')
    deliver_account_webhooks(payload, account)
  end

  def pipeline_item_updated(event)
    pipeline_item = event.data[:pipeline_item]
    changed_attributes = event.data[:changed_attributes] || {}
    return if changed_attributes.blank?

    account = single_tenant_account
    payload = pipeline_item.webhook_data.merge(
      event: 'pipeline_item.updated',
      changed_attributes: changed_attributes
    )
    deliver_account_webhooks(payload, account)
  end

  def pipeline_item_completed(event)
    pipeline_item = event.data[:pipeline_item]
    account = single_tenant_account
    payload = pipeline_item.webhook_data.merge(event: 'pipeline_item.completed')
    deliver_account_webhooks(payload, account)
  end

  def pipeline_item_cancelled(event)
    pipeline_item = event.data[:pipeline_item]
    account = single_tenant_account
    payload = pipeline_item.webhook_data.merge(event: 'pipeline_item.cancelled')
    deliver_account_webhooks(payload, account)
  end

  private

  def handle_typing_status(event_name, event)
    conversation = event.data[:conversation]
    user = event.data[:user] || conversation.inbox.agent_bot
    inbox = conversation.inbox

    payload = {
      event: event_name,
      user: user&.webhook_data,
      conversation: conversation.webhook_data,
      is_private: event.data[:is_private] || false
    }
    deliver_webhook_payloads(payload, inbox)
  end

  def deliver_account_webhooks(payload, _account = nil)
    Webhook.account_type.each do |webhook|
      next unless webhook.subscriptions.include?(payload[:event])
      next if payload[:inbox].present? && webhook.inbox_id.present? && webhook.inbox_id != payload[:inbox][:id]

      WebhookJob.perform_later(webhook.url, payload)
    end
  end

  def deliver_api_inbox_webhooks(payload, inbox)
    return unless inbox.channel_type == 'Channel::Api'
    return if inbox.channel.webhook_url.blank?

    WebhookJob.perform_later(inbox.channel.webhook_url, payload, :api_inbox_webhook)
  end

  def deliver_webhook_payloads(payload, inbox)
    deliver_account_webhooks(payload, single_tenant_account)
    deliver_api_inbox_webhooks(payload, inbox)
  end
end
