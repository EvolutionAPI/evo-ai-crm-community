# frozen_string_literal: true

module EvoFlow
  # Subscribes to Wisper :purchase_approved (Webhooks::Purchases::LeadCaptureService)
  # and forwards it to evo-flow as `purchase.approved` (CRM-316).
  #
  # `evo_flow_enabled?` is duplicated across the EvoFlow listeners by design
  # (tech-spec §Technical Decisions #2: no shared base class).
  class PurchaseEventsListener
    TRACK_PATH = '/events/track'
    EVENT_NAME = 'purchase.approved'
    # Same value the capture stamps on the card, so event and card agree.
    SOURCE = Webhooks::Purchases::LeadCaptureService::LEAD_SOURCE

    def purchase_approved(data)
      return if data.respond_to?(:data)

      event_data = data[:data] || data
      contact = event_data[:contact]
      pipeline_item = event_data[:pipeline_item]
      unless contact && pipeline_item
        Rails.logger.error('EvoFlow::PurchaseEventsListener#purchase_approved: contact or pipeline_item is nil')
        return
      end
      return unless evo_flow_enabled?

      enqueue_track(contact, pipeline_item, event_data)
    rescue StandardError => e
      log_failure(__method__, e)
    end

    private

    def enqueue_track(contact, pipeline_item, event_data)
      purchase = (event_data[:purchase] || {}).with_indifferent_access
      # One purchase = one event, however many times the platform redelivers
      # or the listener retries: the id is the purchase identity, not the clock.
      source_event_uuid = "#{event_data[:provider]}.#{purchase[:purchase_id]}"
      message_id = EvoFlow::PayloadBuilder.message_id_for(EVENT_NAME, contact.id, source_event_uuid)
      payload = EvoFlow::PayloadBuilder.build_track(
        event_name: EVENT_NAME,
        contact_id: contact.id,
        properties: build_properties(contact, pipeline_item, event_data, purchase),
        occurred_at: Time.current,
        message_id: message_id
      )
      EvoFlow::PublishEventWorker.perform_async(TRACK_PATH, JSON.parse(payload.to_json), current_tenant_id)
    end

    # Optional fields that resolve to nil are OMITTED, never sent as null —
    # the evo-flow schema pipe rejects explicit null for typed fields.
    def build_properties(contact, pipeline_item, event_data, purchase)
      pipeline = pipeline_item.pipeline
      stage = pipeline_item.pipeline_stage
      {
        provider: event_data[:provider].to_s,
        purchase_id: purchase[:purchase_id].to_s,
        pipeline_id: pipeline_item.pipeline_id,
        pipeline_item_id: pipeline_item.id,
        source: SOURCE,
        product: purchase[:product],
        amount: numeric_amount(purchase[:amount]),
        currency: purchase[:currency],
        platform_event: purchase[:event],
        outcome: event_data[:outcome].to_s,
        new_contact: event_data[:new_contact] == true,
        contact_id: contact.id,
        pipeline_name: pipeline&.name,
        pipeline_stage_id: pipeline_item.pipeline_stage_id,
        pipeline_stage_name: stage&.name
      }.compact
    end

    # Adapters hand the amount over as the platform sent it (string or number);
    # the contract says a finite number — NaN/Infinity would blow up to_json.
    def numeric_amount(value)
      return nil if value.blank?

      amount = Float(value)
      amount.finite? ? amount : nil
    rescue ArgumentError, TypeError
      nil
    end

    def evo_flow_enabled?
      EvoFlow.enabled?
    end

    def log_failure(handler, error)
      tag = enqueue_loss?(error) ? '[EvoFlow][enqueue-loss]' : '[EvoFlow]'
      Rails.logger.error(
        "#{tag} EvoFlow::PurchaseEventsListener##{handler} failed: #{error.class}: #{error.message}"
      )
      Sentry.capture_exception(error) if defined?(Sentry)
      nil
    end

    def enqueue_loss?(error)
      return true if defined?(Redis::BaseConnectionError) && error.is_a?(Redis::BaseConnectionError)

      error.is_a?(ArgumentError) && error.message.include?('occurred_at is required')
    end

    # Bound by the enterprise around_action on the webhook; the seam hands it
    # over so the publish carries X-Evo-Tenant-Id. Community: nil, no header.
    def current_tenant_id
      EvoExtensionPoints::RuntimeContext.current_scope_id
    end
  end
end
