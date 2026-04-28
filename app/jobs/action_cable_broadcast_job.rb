class ActionCableBroadcastJob < ApplicationJob
  queue_as :realtime
  include Events::Types

  CONVERSATION_UPDATE_EVENTS = [
    CONVERSATION_READ,
    CONVERSATION_UPDATED,
    TEAM_CHANGED,
    ASSIGNEE_CHANGED,
    CONVERSATION_STATUS_CHANGED
  ].freeze

  def perform(members, event_name, data)
    return if members.blank?

    Rails.logger.info "ActionCable broadcast start job_id=#{job_id} event=#{event_name} recipients=#{members.size}"
    broadcast_data = prepare_broadcast_data(event_name, data)
    broadcast_to_members(members, event_name, broadcast_data)
    Rails.logger.info "ActionCable broadcast done job_id=#{job_id} event=#{event_name}"
  end

  private

  # Ensures that only the latest available data is sent to prevent UI issues
  # caused by out-of-order events during high-traffic periods. This prevents
  # the conversation job from processing outdated data.
  def prepare_broadcast_data(event_name, data)
    return data unless CONVERSATION_UPDATE_EVENTS.include?(event_name)

    conversation_id = data[:id] || data['id']
    conversation = Conversation.find_by!(id: conversation_id)
    conversation.push_event_data
  end

  def broadcast_to_members(members, event_name, broadcast_data)
    members.each do |member|
      ActionCable.server.broadcast(
        member,
        {
          event: event_name,
          data: broadcast_data
        }
      )
    end
  end
end
