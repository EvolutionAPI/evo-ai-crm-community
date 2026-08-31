# frozen_string_literal: true

# Resolves a channel's live connection state for the /inboxes payload
# (EVO-1674). This module is the single source-of-truth map per channel type:
#
#   Whatsapp (hub-managed)             -> provider_config.evolution_hub.status
#   Whatsapp (QR providers)            -> provider_connection['connection']
#   Whatsapp (token providers)         -> recorded credential probe, else unknown
#                                         (probe expires where a job renews it)
#   Email                              -> configured == assumed connected
#   Sendgrid                           -> webhook_registration_status
#   FacebookPage / Instagram (hub)     -> evolution_hub_meta['status']
#   FacebookPage / Instagram (classic) -> unknown (no health signal exists)
#   everything else                    -> unknown (no health signal exists)
#
# `source` tells the client where the answer came from: 'provider_event'
# (webhook/event-fed), 'stored_flag' (read off what we stored about the
# channel), or 'none' (channel type has no health support — degrade explicitly
# in the UI).
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
      # hub_managed? is private on the model, so read the config directly. The
      # block makes a channel hub-managed for life: falling through to the
      # provider branch would answer for the Hub without a Hub event.
      hub_block = channel.provider_config['evolution_hub'] if channel.provider_config.is_a?(Hash)
      return [HUB_STATUS_MAP.fetch(hub_block['status'].to_s, 'unknown'), 'provider_event'] if hub_block.is_a?(Hash)

      if QR_PROVIDERS.include?(channel.provider)
        connection = channel.provider_connection.is_a?(Hash) ? channel.provider_connection['connection'] : nil
        [CONNECTION_MAP.fetch(connection.to_s, 'unknown'), 'provider_event']
      else
        token_based_state(channel)
      end
    end

    # How long a credential probe keeps counting as evidence. Sized well above
    # the re-probe cadence (see Channels::Whatsapp::CredentialProbeSchedulerJob)
    # so a healthy channel waiting its turn in the batch is never degraded —
    # only a channel nothing has re-probed for a week falls out.
    CREDENTIALS_TTL = 7.days

    # Token-based providers have no session event stream: the credential probe
    # is their only evidence of a working connection.
    def token_based_state(channel)
      verified_at = credentials_verified_at(channel)
      return %w[unknown stored_flag] if verified_at.nil?
      # The expiry only applies where something renews the evidence. On a
      # provider nobody re-probes it would degrade every healthy channel to
      # unknown at the end of the window, trading one wrong answer for another.
      return %w[unknown stored_flag] if expirable?(channel) && verified_at < CREDENTIALS_TTL.ago

      %w[connected stored_flag]
    end

    def expirable?(channel)
      Channel::Whatsapp::CREDENTIAL_PROBE_PROVIDERS.include?(channel.provider)
    end

    # A stamp that does not parse, or that sits in the future, is not evidence.
    def credentials_verified_at(channel)
      raw = channel.provider_connection['credentials_verified_at'] if channel.provider_connection.is_a?(Hash)
      return nil if raw.blank?

      parsed = Time.zone.parse(raw.to_s)
      parsed if parsed && parsed <= Time.current
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
      # A page connected by the classic Meta OAuth carries no hub meta at all:
      # nothing feeds it events, so claim no health source instead of an
      # 'unknown' the UI would read as a channel in trouble.
      return %w[unknown none] unless meta.is_a?(Hash) && meta.present?

      [HUB_STATUS_MAP.fetch(meta['status'].to_s, 'unknown'), 'provider_event']
    end

    def reauthorization_required?(channel)
      channel.respond_to?(:reauthorization_required?) && channel.reauthorization_required?
    end
  end
end
