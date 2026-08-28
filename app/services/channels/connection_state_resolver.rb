# frozen_string_literal: true

# Resolves a channel's live connection state for the /inboxes payload
# (EVO-1674). This module is the single source-of-truth map per channel type:
#
#   Whatsapp (hub-managed)            -> provider_config.evolution_hub.status
#   Whatsapp (QR providers)           -> provider_connection['connection']
#   Whatsapp (token providers)        -> recorded credential probe, else unknown
#   Email                             -> configured == assumed connected
#   Sendgrid                          -> webhook_registration_status
#   FacebookPage / Instagram          -> evolution_hub_meta['status']
#   everything else                   -> unknown (no health signal exists)
#
# Email is the one line above still reading a channel as connected purely
# because it is configured — it has no probe to record and no event stream, so
# the assumption stands here knowingly, not by oversight.
#
# `source` tells the client where the answer came from: 'provider_event'
# (webhook/event-fed), 'stored_flag' (read off what we stored about the
# channel — which can be evidence, as in a recorded credential probe, or the
# absence of it), or 'none' (channel type has no health support — degrade
# explicitly in the UI).
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
    QR_PROVIDERS = %w[evolution evolution_go zapi].freeze

    # Evolution Hub lifecycle status -> connection state. 'inactive' is the Hub
    # telling us the Meta connection went away (token revoked, channel removed
    # at the Hub); anything outside this map is a status we cannot read.
    HUB_STATUS_MAP = {
      'active' => 'connected',
      'pending' => 'pending',
      'inactive' => 'disconnected'
    }.freeze

    # How long a successful credential probe stands as evidence. The probe
    # proves the credentials worked when they were written, not that they still
    # work today, so past this window a token-based channel goes back to
    # 'unknown' instead of coasting on an ever-older assertion.
    CREDENTIAL_EVIDENCE_TTL = 30.days

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
      # hub_managed? is private on Channel::Whatsapp — read the config
      # directly. A channel carrying an evolution_hub block is
      # hub-managed for its whole life, so the Hub lifecycle owns its state
      # end to end — falling through to the provider branch on a status the
      # map doesn't cover would answer for the Hub without a Hub event.
      hub_block = channel.provider_config['evolution_hub'] if channel.provider_config.is_a?(Hash)
      return [HUB_STATUS_MAP.fetch(hub_block['status'].to_s, 'unknown'), 'provider_event'] if hub_block.is_a?(Hash)

      if QR_PROVIDERS.include?(channel.provider)
        connection = channel.provider_connection.is_a?(Hash) ? channel.provider_connection['connection'] : nil
        [CONNECTION_MAP.fetch(connection.to_s, 'unknown'), 'provider_event']
      else
        token_based_state(channel)
      end
    end

    # Token-based providers (whatsapp_cloud, 360dialog, notificame) have no
    # session event stream, so there is nothing to infer a live connection
    # from. Their only real evidence is the credential probe that
    # Channel::Whatsapp#stamp_credentials_verified records on save; without a
    # readable, still-fresh stamp the honest answer is 'unknown', never
    # 'connected'.
    def token_based_state(channel)
      verified_at = credentials_verified_at(channel)
      fresh = verified_at.present? && verified_at > CREDENTIAL_EVIDENCE_TTL.ago

      fresh ? %w[connected stored_flag] : %w[unknown stored_flag]
    end

    # An unreadable stamp is not evidence: parse it rather than trusting any
    # non-blank value that happens to sit under the key.
    def credentials_verified_at(channel)
      raw = channel.provider_connection['credentials_verified_at'] if channel.provider_connection.is_a?(Hash)
      return nil if raw.blank?

      Time.zone.parse(raw.to_s)
    rescue ArgumentError, TypeError
      nil
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

      [HUB_STATUS_MAP.fetch(status.to_s, 'unknown'), 'provider_event']
    end

    def reauthorization_required?(channel)
      channel.respond_to?(:reauthorization_required?) && channel.reauthorization_required?
    end
  end
end
