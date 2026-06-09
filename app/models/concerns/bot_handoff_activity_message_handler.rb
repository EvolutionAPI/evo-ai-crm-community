# frozen_string_literal: true

# Persists the AI→human handoff as a timeline activity message (EVO-1560), so
# the transition is durable and renders in the conversation history alongside
# the existing status/assignee/label activities.
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
end
