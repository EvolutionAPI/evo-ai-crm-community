# frozen_string_literal: true

# Persists handoff transitions as timeline activity messages (EVO-1560 forward
# bot→human; EVO-1680 reverse human→bot), so transitions are durable and render
# in the conversation history alongside status/assignee/label activities.
module BotHandoffActivityMessageHandler
  extend ActiveSupport::Concern

  private

  def create_bot_handoff_activity
    # Only log a real transition: skip when bot_handoff! runs on an
    # already-open conversation (open! is then a no-op).
    return unless saved_change_to_status?

    content = I18n.t('conversations.activity.bot_handoff')
    params = activity_message_params(content).merge(content_attributes: { handoff_type: 'bot_to_human' })
    ::Conversations::ActivityMessageJob.perform_later(self, params)
  end

  def create_human_handoff_activity
    # Mirror of the forward path. return_to_bot! already gates on status==open,
    # so the saved_change_to_status? guard is defensive: a future caller that
    # invokes this method without a real transition will not log a stray activity.
    return unless saved_change_to_status?

    content = I18n.t('conversations.activity.human_handoff')
    params = activity_message_params(content).merge(content_attributes: { handoff_type: 'human_to_bot' })
    ::Conversations::ActivityMessageJob.perform_later(self, params)
  end
end
