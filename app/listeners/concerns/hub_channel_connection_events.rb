# frozen_string_literal: true

# Pushes a Hub-relayed Meta channel connection change to the screen waiting on
# the Hub tab to come back.
#
# Lives in a concern rather than in ActionCableListener's body because that
# class already sits at the Metrics/ClassLength ceiling.
module HubChannelConnectionEvents
  include Events::Types

  # Goes to every user, not just whoever clicked: the signup can be resumed from
  # another tab or by another operator, and the state belongs to the channel.
  def hub_channel_connection_changed(event)
    inbox = event.data[:inbox]
    return if inbox.blank?

    payload = {
      inbox_id: inbox.id,
      channel_type: inbox.channel_type,
      connection_status: event.data[:connection_status]
    }

    # Single-tenant install: Inbox does not expose `account`.
    broadcast(single_tenant_account, User.pluck(:pubsub_token).compact.uniq,
              HUB_CHANNEL_CONNECTION_CHANGED, payload)
  end
end
