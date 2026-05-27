# frozen_string_literal: true

# Async processor for everything coming in via /webhooks/evolution_hub.
# Two flavours of payload to handle:
#
#   - Hub lifecycle events (top-level "event_type"): mutate the local Channel
#     to reflect what happened in the Hub (channel_connected populates the
#     Meta credentials and flips status to active; channel_disconnected flips
#     it to inactive; channel_auto_imported records the Hub channel_token).
#
#   - Forwarded Meta webhooks: payload shape is exactly what Meta posts, with
#     "object" telling us the platform. We dispatch into the existing per-
#     platform jobs (FacebookEventsJob, WhatsappEventsJob-equivalent) so the
#     handlers downstream are unchanged.
#
# Dedup is by X-Hub-Delivery-Id passed in from the controller, using a Redis
# SETNX with 5min TTL. Same dispatcher retries → same delivery id → skipped.
module Webhooks
  # Nested style (open the module first) so Sidekiq 8's deserializer can resolve
  # `Webhooks::EvolutionHubEventsJob` via Object.const_get even when the
  # constant cache hasn't autoloaded the namespace yet at retry time.
  class EvolutionHubEventsJob < ApplicationJob
    queue_as :default

  DEDUP_TTL_SECONDS = 300

  HUB_EVENT_TYPES = %w[
    channel_connected
    channel_disconnected
    channel_auto_imported
    webhook_delivered
    webhook_failed
    proxy_api_used
  ].freeze

  def perform(raw_body, delivery_id)
    return unless acquire_dedup_lock(delivery_id)

    payload = JSON.parse(raw_body)

    if hub_lifecycle_event?(payload)
      process_hub_lifecycle(payload)
    elsif forwarded_meta_event?(payload)
      forward_to_meta_pipeline(raw_body, payload)
    else
      Rails.logger.warn("EvolutionHub: unrecognised payload shape (event_type=#{payload['event_type'].inspect} object=#{payload['object'].inspect})")
    end
  rescue JSON::ParserError => e
    Rails.logger.error("EvolutionHub: failed to parse webhook body — #{e.message}")
  end

  private

  def acquire_dedup_lock(delivery_id)
    return true if delivery_id.blank?

    key = "evolution_hub:delivery:#{delivery_id}"
    # SET NX EX 300 — only returns truthy when the key did NOT already exist.
    Redis::Alfred.setex(key, '1', DEDUP_TTL_SECONDS) ? true : false
  rescue StandardError => e
    Rails.logger.warn("EvolutionHub: dedup lock unavailable (#{e.class}: #{e.message}); processing anyway")
    true
  end

  def hub_lifecycle_event?(payload)
    # Hub envia 'event' (atual) — 'event_type' é forward-compat caso o Hub
    # mude o nome do campo. Aceita ambos pra não quebrar com upgrade.
    type = payload['event'] || payload['event_type']
    HUB_EVENT_TYPES.include?(type)
  end

  def forwarded_meta_event?(payload)
    %w[whatsapp_business_account page instagram].include?(payload['object'])
  end

  def process_hub_lifecycle(payload)
    type = payload['event'] || payload['event_type']
    case type
    when 'channel_connected'      then EvolutionHub::ChannelConnectedHandler.new(payload).perform
    when 'channel_disconnected'   then EvolutionHub::ChannelDisconnectedHandler.new(payload).perform
    when 'channel_auto_imported'  then EvolutionHub::ChannelAutoImportedHandler.new(payload).perform
    else
      # webhook_delivered/failed/proxy_api_used are informational. Log and move on.
      Rails.logger.info("EvolutionHub: lifecycle event #{type} for channel=#{payload['external_id'] || payload.dig('channel', 'external_id')}")
    end
  end

  def forward_to_meta_pipeline(raw_body, payload)
    # The per-platform jobs (Whatsapp/Facebook/InstagramEventsJob) read params
    # with symbol keys (`params[:object]`, `params[:instance]`, etc.). The
    # native Webhooks::WhatsappController uses `params.to_unsafe_hash`, which
    # gives an ActionController::Parameters-backed hash with indifferent
    # access — symbol *and* string keys both work. Our JSON.parse produces a
    # plain string-keyed Hash, so we must wrap it before enqueueing or every
    # `params[:object]` lookup downstream returns nil and the job logs
    # "no channel found for params {}".
    forward_payload = payload.with_indifferent_access

    case payload['object']
    when 'whatsapp_business_account'
      Webhooks::WhatsappEventsJob.perform_later(forward_payload) if defined?(Webhooks::WhatsappEventsJob)
    when 'page'
      Webhooks::FacebookEventsJob.perform_later(forward_payload)
    when 'instagram'
      Webhooks::InstagramEventsJob.perform_later(forward_payload) if defined?(Webhooks::InstagramEventsJob)
    end
  end
  end
end
