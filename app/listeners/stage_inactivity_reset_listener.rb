# Resets `no_customer_reply` stage-inactivity executions when the customer
# sends an incoming message. This MUST be its own listener (not piggybacked on
# AgentBotListener) because AgentBotListener bails out early for inboxes without
# a connected agent bot, while stage inactivity rules apply to ALL inboxes.
class StageInactivityResetListener < BaseListener
  def message_created(event)
    message = extract_message_and_account(event)[0]
    return unless message&.incoming?

    conversation = message.conversation
    return if conversation.nil?

    pipeline_item_ids = conversation.pipeline_items.pluck(:id)
    return if pipeline_item_ids.empty?

    pipeline_item_ids.each do |item_id|
      StageInactivityExecution.reset_for_item(item_id, base: 'no_customer_reply')
    end
  rescue StandardError => e
    Rails.logger.error "[StageInactivityReset] #{e.message}"
  end
end
