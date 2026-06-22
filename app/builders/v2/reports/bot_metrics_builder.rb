class V2::Reports::BotMetricsBuilder
  include DateRangeHelper
  attr_reader :params

  def initialize(_account = nil, params = nil)
    @params = params
  end

  def metrics
    {
      conversation_count: bot_conversations.count,
      message_count: bot_messages.count,
      resolution_rate: bot_resolution_rate.to_i,
      handoff_rate: bot_handoff_rate.to_i
    }
  end

  private

  def bot_activated_inbox_ids
    # Restrict bot metrics to the caller's accessible inboxes (admin/read_all/opt-in
    # via assigned_inboxes); degrade to all inboxes when there is no request user.
    scope = Current.user&.assigned_inboxes || Inbox.all
    @bot_activated_inbox_ids ||= scope.filter(&:active_bot?).map(&:id)
  end

  def bot_conversations
    @bot_conversations ||= Conversation.where(inbox_id: bot_activated_inbox_ids).where(created_at: range)
  end

  def bot_messages
    @bot_messages ||= Message.outgoing.where(conversation_id: bot_conversations.ids).where(created_at: range)
  end

  def bot_resolutions_count
    ReportingEvent.joins(:conversation).select(:conversation_id).where(name: :conversation_bot_resolved,
                                                                       created_at: range).distinct.count
  end

  def bot_handoffs_count
    ReportingEvent.joins(:conversation).select(:conversation_id).where(name: :conversation_bot_handoff,
                                                                       created_at: range).distinct.count
  end

  def bot_resolution_rate
    return 0 if bot_conversations.count.zero?

    bot_resolutions_count.to_f / bot_conversations.count * 100
  end

  def bot_handoff_rate
    return 0 if bot_conversations.count.zero?

    bot_handoffs_count.to_f / bot_conversations.count * 100
  end
end
