# frozen_string_literal: true

# Resolves a channel's live connection state for the /inboxes payload
# (EVO-1674). This module is the single source-of-truth map per channel type:
#
#   Whatsapp (hub-managed)            -> provider_config.evolution_hub.status
#   Whatsapp (QR providers)           -> provider_connection['connection']
#   Whatsapp (token providers)        -> configured == assumed connected
#   Email                             -> configured == assumed connected
#   Sendgrid                          -> webhook_registration_status
#   FacebookPage / Instagram          -> evolution_hub_meta['status']
#   everything else                   -> unknown (no health signal exists)
#
# `source` tells the client how trustworthy the state is: 'provider_event'
# (webhook/event-fed), 'stored_flag' (assumed from configuration), or 'none'
# (channel type has no health support — degrade explicitly in the UI).
module Channels
  module ConnectionStateResolver
    extend self

    # provider_connection['connection'] values seen from Baileys/Evolution
    # connection.update events.
    CONNECTION_MAP = {
      'open' => 'connected',
      'connected' => 'connected',
      'connecting' => 'pending',
      'close' => 'disconnected',
      'closed' => 'disconnected',
      'disconnected' => 'disconnected'
    }.freeze

    # Providers whose session lives on a QR-paired instance and report
    # connection.update events into provider_connection.
    QR_PROVIDERS = %w[baileys evolution evolution_go zapi].freeze

    # @param channel [ApplicationRecord, nil] the inbox's channel
    # @return [Hash] { state:, source:, last_sync:, reauthorization_required: }
    def call(channel)
      return { state: 'unknown', source: 'none', last_sync: nil, reauthorization_required: false } if channel.nil?

      state, source = state_for(channel)
      reauth = reauthorization_required?(channel)
      # Reauthorization is the strongest stored signal: the provider rejected
      # our credentials, so whatever the event-fed state says, the channel
      # cannot deliver until an admin re-authorizes.
      state = 'error' if reauth

      { state: state, source: source, last_sync: channel.updated_at, reauthorization_required: reauth }
    end

    private

    def state_for(channel)
      case channel
      when Channel::Whatsapp then whatsapp_state(channel)
      when Channel::Email then %w[connected stored_flag]
      when Channel::Sendgrid then sendgrid_state(channel)
      when Channel::FacebookPage, Channel::Instagram then hub_state(channel)
      else %w[unknown none]
      end
    end

    def whatsapp_state(channel)
      # hub_active?/hub_pending? are private on Channel::Whatsapp — read the
      # config directly.
      hub_status = channel.provider_config.is_a?(Hash) ? channel.provider_config.dig('evolution_hub', 'status') : nil
      return %w[connected provider_event] if hub_status == 'active'
      return %w[pending provider_event] if hub_status == 'pending'

      if QR_PROVIDERS.include?(channel.provider)
        connection = channel.provider_connection.is_a?(Hash) ? channel.provider_connection['connection'] : nil
        [CONNECTION_MAP.fetch(connection.to_s, 'unknown'), 'provider_event']
      else
        # Token-based providers (whatsapp_cloud, 360dialog, notificame): there
        # is no session event stream; a configured channel is assumed live
        # until a reauthorization flag says otherwise.
        %w[connected stored_flag]
      end
    end

    def sendgrid_state(channel)
      case channel.webhook_registration_status
      when 'active' then %w[connected provider_event]
      when 'pending' then %w[pending provider_event]
      when 'failed' then %w[error provider_event]
      else %w[unknown provider_event]
      end
    end

    def hub_state(channel)
      meta = channel.evolution_hub_meta
      status = meta.is_a?(Hash) ? meta['status'] : nil

      case status
      when 'active' then %w[connected provider_event]
      when 'pending' then %w[pending provider_event]
      when 'inactive' then %w[disconnected provider_event]
      else %w[unknown provider_event]
      end
    end

    def reauthorization_required?(channel)
      channel.respond_to?(:reauthorization_required?) && channel.reauthorization_required?
    end
  end
end
