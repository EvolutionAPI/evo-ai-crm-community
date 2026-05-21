# frozen_string_literal: true

module EvoFlow
  # Subscribes to Wisper :contact_* events and forwards them to evo-flow
  # via EvoFlow::PublishEventWorker. Identify payloads (/events/identify).
  # Template: dual-shape guard, unpack, nil-check, ENV gate, build via
  # PayloadBuilder, deterministic messageId, enqueue, rescue+log.
  # `evo_flow_enabled?` is duplicated across the 4 listeners by design
  # (tech-spec §Technical Decisions #2: no shared base class).
  class ContactEventsListener
    IDENTIFY_PATH = '/events/identify'

    def contact_created(data)
      return if data.respond_to?(:data)

      event_data = data[:data] || data
      contact = event_data[:contact]
      return log_missing(__method__, 'contact') unless contact
      return unless evo_flow_enabled?

      traits = build_contact_traits(contact).merge(
        source: 'contact_created',
        created_via: created_via(contact)
      )
      enqueue_identify(
        event_name: 'contact.created',
        contact_id: contact.id,
        traits: traits,
        occurred_at: contact.created_at,
        source_event_uuid: "#{contact.id}.#{contact.created_at.to_i}"
      )
    rescue StandardError => e
      log_failure(__method__, e)
    end

    def contact_updated(data)
      return if data.respond_to?(:data)

      event_data = data[:data] || data
      contact = event_data[:contact]
      return log_missing(__method__, 'contact') unless contact
      return unless evo_flow_enabled?

      traits = build_contact_traits(contact).merge(
        source: 'contact_updated',
        changes: summarise_changes(event_data)
      )
      enqueue_identify(
        event_name: 'contact.updated',
        contact_id: contact.id,
        traits: traits,
        occurred_at: contact.updated_at,
        source_event_uuid: "#{contact.id}.#{contact.updated_at.to_i}"
      )
    rescue StandardError => e
      log_failure(__method__, e)
    end

    def contact_deleted(data)
      return if data.respond_to?(:data)

      event_data = data[:data] || data
      contact_id = resolve_deleted_contact_id(event_data)
      return log_missing(__method__, 'contact_id') unless contact_id
      return unless evo_flow_enabled?

      # F1: prefer `contact.updated_at` over `Time.zone.now` for idempotency.
      deleted_at = resolve_deleted_at(event_data)
      enqueue_identify(
        event_name: 'contact.deleted',
        contact_id: contact_id,
        traits: build_deleted_traits(event_data, deleted_at),
        occurred_at: deleted_at,
        source_event_uuid: "#{contact_id}.#{deleted_at.to_i}"
      )
    rescue StandardError => e
      log_failure(__method__, e)
    end

    def contact_label_added(data)
      handle_label_change(data, event_name: 'contact.label.added', source: 'label_added', suffix: 'added')
    end

    def contact_label_removed(data)
      handle_label_change(data, event_name: 'contact.label.removed', source: 'label_removed', suffix: 'removed')
    end

    def contact_custom_attribute_changed(data)
      return if data.respond_to?(:data)

      event_data = data[:data] || data
      contact = event_data[:contact]
      return log_missing(__method__, 'contact') unless contact
      return unless evo_flow_enabled?

      # L3: prefer producer-supplied timestamp; fall back to now.
      occurred_at = event_data[:occurred_at] || Time.zone.now
      enqueue_identify(
        event_name: 'contact.custom_attribute.changed',
        contact_id: contact.id,
        traits: build_attribute_change_traits(event_data),
        occurred_at: occurred_at,
        # F2: include old_value + timestamp so toggle sequences don't collide.
        source_event_uuid: custom_attribute_uuid(contact, event_data, occurred_at)
      )
    rescue StandardError => e
      log_failure(__method__, e)
    end

    private

    def handle_label_change(data, event_name:, source:, suffix:)
      return if data.respond_to?(:data)

      event_data = data[:data] || data
      contact = event_data[:contact]
      return log_missing("contact_label_#{suffix}", 'contact') unless contact
      return unless evo_flow_enabled?

      label_name = event_data[:label_name]
      # L2: prefer the real Label.id from the producer (event_data[:label_id]);
      # fall back to a Label lookup for backwards compat with producers that
      # only pass the name. If neither yields an id, fall back to the name.
      label_id = event_data[:label_id] || resolve_label_id(label_name) || label_name
      traits = { labelName: label_name, labelId: label_id, source: source }
      # L3: prefer producer-supplied timestamp; fall back to now.
      occurred_at = event_data[:occurred_at] || Time.zone.now

      enqueue_identify(
        event_name: event_name,
        contact_id: contact.id,
        traits: traits,
        occurred_at: occurred_at,
        # F3: include timestamp so add→remove→add-again doesn't collide.
        source_event_uuid: "#{contact.id}.#{label_name}.#{suffix}.#{occurred_at.to_i}"
      )
    rescue StandardError => e
      log_failure("contact_label_#{suffix}", e)
    end

    def resolve_label_id(label_name)
      return nil if label_name.blank?

      Label.find_by(title: label_name.to_s)&.id
    end

    def created_via(contact)
      contact.additional_attributes&.dig('created_via_user_id').present? ? 'agent' : 'system'
    end

    def summarise_changes(event_data)
      raw = event_data[:changed_attributes] || event_data[:changes] || {}
      raw.transform_values { |v| v.is_a?(Array) ? v.last : v }
    end

    def resolve_deleted_contact_id(event_data)
      event_data[:contact]&.id || event_data[:contact_id]
    end

    def resolve_deleted_at(event_data)
      contact = event_data[:contact]
      event_data[:deleted_at] || (contact.respond_to?(:updated_at) && contact.updated_at) || Time.zone.now
    end

    def custom_attribute_uuid(contact, event_data, occurred_at)
      "#{contact.id}.#{event_data[:attribute_name]}.#{event_data[:attribute_value]}.#{event_data[:old_value]}.#{occurred_at.to_i}"
    end

    def build_deleted_traits(event_data, deleted_at)
      { source: 'contact_deleted', reason: event_data[:reason] || 'user_action', deleted_at: deleted_at.iso8601 }
    end

    def build_attribute_change_traits(event_data)
      {
        attributeName: event_data[:attribute_name], attributeValue: event_data[:attribute_value],
        changeType: event_data[:change_type], oldValue: event_data[:old_value],
        source: 'custom_attribute_changed'
      }.compact
    end

    def enqueue_identify(event_name:, contact_id:, traits:, occurred_at:, source_event_uuid:)
      message_id = EvoFlow::PayloadBuilder.message_id_for(event_name, contact_id, source_event_uuid)
      payload = EvoFlow::PayloadBuilder.build_identify(
        event_name: event_name,
        contact_id: contact_id,
        traits: traits,
        occurred_at: occurred_at,
        message_id: message_id
      )
      # Sidekiq strict_args!(:raise) rejects symbol keys and non-JSON values;
      # round-tripping through JSON normalises both at the listener boundary.
      EvoFlow::PublishEventWorker.perform_async(IDENTIFY_PATH, JSON.parse(payload.to_json))
    end

    # Ported from legacy evo_campaign/contact_events_integration_service.rb:553-571.
    # M4: custom_attributes / additional_attributes are namespaced rather than
    # spread, so a custom attribute named `id`/`name`/`email`/`created_at`
    # cannot overwrite the structural trait keys.
    def build_contact_traits(contact)
      {
        id: contact.id,
        name: contact.name,
        email: contact.email,
        phone_number: contact.phone_number,
        identifier: contact.identifier,
        middle_name: contact.middle_name,
        last_name: contact.last_name,
        location: contact.location,
        country_code: contact.country_code,
        contact_type: contact.contact_type,
        blocked: contact.blocked,
        created_at: contact.created_at,
        updated_at: contact.updated_at,
        customAttributes: contact.custom_attributes || {},
        additionalAttributes: contact.additional_attributes || {}
      }.compact
    end

    def evo_flow_enabled?
      EvoFlow.enabled?
    end

    def log_missing(handler, key)
      Rails.logger.error("EvoFlow::ContactEventsListener##{handler}: #{key} is nil")
      nil
    end

    # F6/F8: rescue is broad-by-design; tag enqueue-loss so ops can alert.
    def log_failure(handler, error)
      tag = enqueue_loss?(error) ? '[EvoFlow][enqueue-loss]' : '[EvoFlow]'
      Rails.logger.error("#{tag} EvoFlow::ContactEventsListener##{handler} failed: #{error.class}: #{error.message}")
      Sentry.capture_exception(error) if defined?(Sentry)
      nil
    end

    def enqueue_loss?(error)
      (defined?(Redis::BaseConnectionError) && error.is_a?(Redis::BaseConnectionError)) ||
        (error.is_a?(ArgumentError) && error.message.include?('occurred_at is required'))
    end
  end
end
