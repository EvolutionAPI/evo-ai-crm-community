# frozen_string_literal: true

# Announces a Hub-relayed Meta channel connection change to the operator's
# screen. Shared by the channel_connected/channel_disconnected handlers so the
# two directions cannot drift apart.
module EvolutionHub
  module ConnectionBroadcast
    CONNECTED = 'connected'
    DISCONNECTED = 'disconnected'

    private

    # A failed announcement must not undo the persistence: the channel already
    # changed state, and not telling the screen beats reprocessing the webhook.
    def broadcast_connection_change(channel, status)
      inbox = channel.inbox
      return if inbox.blank?

      Rails.configuration.dispatcher.dispatch(
        Events::Types::HUB_CHANNEL_CONNECTION_CHANGED,
        Time.zone.now,
        inbox: inbox,
        connection_status: status
      )
    rescue StandardError => e
      Rails.logger.error(
        "EvolutionHub: failed to announce #{status} for channel #{channel.id}: #{e.class}: #{e.message}"
      )
    end
  end
end
