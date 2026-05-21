# frozen_string_literal: true

module EvoFlow
  # Subscribes to Wisper :pipeline_item_created and forwards to evo-flow.
  #
  # Adapter shim: legacy Wisper event :pipeline_item_created maps to the
  # EvoFlow::EVENT_NAMES entry "campaign.triggered". A dedicated `pipeline.*`
  # event name is preferred long-term but requires coordinated evo-flow +
  # downstream consumer changes — out of scope for EVO-1240.
  #
  # `evo_flow_enabled?` is duplicated across the 4 EvoFlow listeners by
  # design (tech-spec §Technical Decisions #2: no shared base class).
  class PipelineEventsListener
    TRACK_PATH = '/events/track'
    EVENT_NAME = 'campaign.triggered'

    def pipeline_item_created(data)
      return if data.respond_to?(:data)

      event_data = data[:data] || data
      pipeline_item = event_data[:pipeline_item]
      unless pipeline_item
        Rails.logger.error('EvoFlow::PipelineEventsListener#pipeline_item_created: pipeline_item is nil')
        return
      end
      return unless evo_flow_enabled?

      contact_id = resolve_contact_id(pipeline_item)
      return warn_unresolved(pipeline_item) unless contact_id

      enqueue_track(pipeline_item, contact_id)
    rescue StandardError => e
      log_failure(__method__, e)
    end

    private

    def enqueue_track(pipeline_item, contact_id)
      source_event_uuid = "#{pipeline_item.id}.#{pipeline_item.created_at.to_i}"
      message_id = EvoFlow::PayloadBuilder.message_id_for(EVENT_NAME, contact_id, source_event_uuid)
      payload = EvoFlow::PayloadBuilder.build_track(
        event_name: EVENT_NAME,
        contact_id: contact_id,
        properties: build_properties(pipeline_item, contact_id),
        occurred_at: pipeline_item.created_at,
        message_id: message_id
      )
      # Sidekiq strict_args!(:raise) rejects symbol keys and non-JSON values;
      # PayloadBuilder is out of scope for this story — normalise at boundary.
      EvoFlow::PublishEventWorker.perform_async(TRACK_PATH, JSON.parse(payload.to_json))
    end

    def resolve_contact_id(pipeline_item)
      if pipeline_item.lead?
        pipeline_item.contact_id
      else
        pipeline_item.conversation&.contact_id
      end
    end

    def warn_unresolved(pipeline_item)
      Rails.logger.warn(
        "EvoFlow::PipelineEventsListener#pipeline_item_created: no resolvable contact_id for pipeline_item #{pipeline_item.id}"
      )
      nil
    end

    # F11 fix: use the resolved contact_id for `contact_id` so deal items
    # carry a consistent value with the payload root `contactId`.
    def build_properties(pipeline_item, contact_id)
      pipeline = pipeline_item.pipeline
      stage = pipeline_item.pipeline_stage
      {
        pipeline_item_id: pipeline_item.id,
        conversation_id: pipeline_item.conversation_id,
        contact_id: contact_id,
        is_lead: pipeline_item.lead?,
        pipeline_id: pipeline_item.pipeline_id,
        pipeline_name: pipeline&.name,
        pipeline_stage_id: pipeline_item.pipeline_stage_id,
        pipeline_stage_name: stage&.name,
        assigned_by_id: pipeline_item.assigned_by_id,
        custom_fields: pipeline_item.custom_fields,
        source: 'pipeline_management'
      }
    end

    def evo_flow_enabled?
      EvoFlow.enabled?
    end

    # F6/F8 mitigation: see ContactEventsListener#log_failure for rationale.
    def log_failure(handler, error)
      tag = enqueue_loss?(error) ? '[EvoFlow][enqueue-loss]' : '[EvoFlow]'
      Rails.logger.error(
        "#{tag} EvoFlow::PipelineEventsListener##{handler} failed: #{error.class}: #{error.message}"
      )
      Sentry.capture_exception(error) if defined?(Sentry)
      nil
    end

    def enqueue_loss?(error)
      return true if defined?(Redis::BaseConnectionError) && error.is_a?(Redis::BaseConnectionError)

      error.is_a?(ArgumentError) && error.message.include?('occurred_at is required')
    end
  end
end
