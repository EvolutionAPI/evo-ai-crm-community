module EvoFlow
  # Ruby mirror of evo-flow/src/modules/events/manifest/event-catalog.ts
  # and evo-ai-frontend-community/src/lib/events-manifest/catalog.ts.
  # The three mirrors are kept in sync by convention; an automated CI sync
  # gate is tracked as a follow-up (no enforcement at the moment).
  #
  # Categories: contact | conversation | message | campaign | custom.
  # FieldType (TS): string | number | boolean | date | uuid | object
  # In Ruby, the validator (EvoFlow::SchemaValidator) maps each type to a
  # concrete predicate — see schema_validator.rb.
  #
  # Wrapped in a class (rather than a top-level EVENT_SCHEMA constant) so
  # Zeitwerk's expected_definition check passes for this file's path.
  class EventSchema
    def self.fetch(event_name)
      DEFINITIONS[event_name]
    end

    # Recursively freezes a hash and any nested hash values so runtime code
    # cannot mutate the schema (defense against accidental in-process edits).
    # Plain `.each_value(&:freeze)` only freezes the outer entries; the
    # inner `required:` / `optional:` hashes stay mutable without this.
    def self.deep_freeze(obj)
      case obj
      when Hash
        obj.each_value { |v| deep_freeze(v) }
        obj.freeze
      end
      obj
    end

    DEFINITIONS = {
    'contact.created' => {
      category: :contact,
      required: { id: :uuid, source: :string },
      optional: {
        name: :string, email: :string, phone_number: :string, identifier: :string,
        middle_name: :string, last_name: :string, location: :string, country_code: :string,
        contact_type: :string, blocked: :boolean, created_at: :date, updated_at: :date,
        customAttributes: :object, additionalAttributes: :object, created_via: :string
      }
    },
    'contact.updated' => {
      category: :contact,
      required: { id: :uuid, source: :string },
      optional: {
        name: :string, email: :string, phone_number: :string, identifier: :string,
        middle_name: :string, last_name: :string, location: :string, country_code: :string,
        contact_type: :string, blocked: :boolean, created_at: :date, updated_at: :date,
        customAttributes: :object, additionalAttributes: :object, created_via: :string,
        changes: :object
      }
    },
    'contact.deleted' => {
      category: :contact,
      required: { source: :string, deleted_at: :date },
      optional: { reason: :string }
    },
    'contact.label.added' => {
      category: :contact,
      required: { labelName: :string, labelId: :string, source: :string },
      optional: {}
    },
    'contact.label.removed' => {
      category: :contact,
      required: { labelName: :string, labelId: :string, source: :string },
      optional: {}
    },
    'contact.custom_attribute.changed' => {
      category: :contact,
      required: { attributeName: :string, source: :string },
      optional: { attributeValue: :string, changeType: :string, oldValue: :string }
    },
    'conversation.created' => {
      category: :conversation,
      required: { conversation_id: :uuid, inbox_id: :uuid, source: :string },
      optional: { inbox_name: :string, channel_type: :string }
    },
    'conversation.resolved' => {
      category: :conversation,
      required: { conversation_id: :uuid, inbox_id: :uuid, source: :string },
      optional: {
        inbox_name: :string, channel_type: :string,
        resolved_by_id: :string, resolved_by_type: :string, resolution_time_seconds: :number
      }
    },
    'conversation.activity' => {
      category: :conversation,
      required: { conversation_id: :uuid, source: :string },
      optional: { inbox_id: :uuid, content: :string, activity_type: :string }
    },
    'conversation.first_reply' => {
      category: :conversation,
      required: { conversation_id: :uuid, source: :string },
      optional: { inbox_id: :uuid, replied_at: :date, response_time_seconds: :number }
    },
    'conversation.reply_time' => {
      category: :conversation,
      required: { conversation_id: :uuid, source: :string },
      optional: { inbox_id: :uuid, reply_time_seconds: :number, measured_at: :date }
    },
    'conversation.bot_handoff' => {
      category: :conversation,
      required: { conversation_id: :uuid, source: :string },
      optional: { inbox_id: :uuid, handoff_at: :date, reason: :string }
    },
    'conversation.bot_resolved' => {
      category: :conversation,
      required: { conversation_id: :uuid, source: :string },
      optional: { inbox_id: :uuid, resolved_at: :date }
    },
    'message.created' => {
      category: :message,
      required: {
        message_id: :uuid, channel_type: :string, conversation_id: :uuid,
        source: :string, message_type: :string
      },
      optional: { content_type: :string, content: :string }
    },
    'message.delivered' => {
      category: :message,
      required: {
        message_id: :uuid, channel_type: :string, conversation_id: :uuid, source: :string
      },
      optional: {
        message_type: :string, content_type: :string, content: :string,
        previous_status: :string, status: :string, external_error: :string
      }
    },
    'message.read' => {
      category: :message,
      required: {
        message_id: :uuid, channel_type: :string, conversation_id: :uuid, source: :string
      },
      optional: {
        message_type: :string, content_type: :string, content: :string,
        previous_status: :string, status: :string, external_error: :string
      }
    },
    'message.failed' => {
      category: :message,
      required: {
        message_id: :uuid, channel_type: :string, conversation_id: :uuid, source: :string
      },
      optional: {
        message_type: :string, content_type: :string, content: :string,
        previous_status: :string, status: :string, external_error: :string
      }
    },
    'campaign.triggered' => {
      category: :campaign,
      required: { pipeline_item_id: :uuid, pipeline_id: :uuid, source: :string },
      optional: {
        conversation_id: :uuid, contact_id: :uuid, is_lead: :boolean,
        pipeline_name: :string, pipeline_stage_id: :uuid, pipeline_stage_name: :string,
        assigned_by_id: :uuid, custom_fields: :object
      }
    },
    'campaign.message.sent' => {
      category: :campaign,
      required: { campaign_id: :uuid, message_id: :uuid, source: :string },
      optional: { contact_id: :uuid, channel_type: :string, template_id: :uuid }
    },
    'campaign.message.opened' => {
      category: :campaign,
      required: { campaign_id: :uuid, message_id: :uuid, source: :string },
      optional: { contact_id: :uuid, opened_at: :date }
    },
    'campaign.message.clicked' => {
      category: :campaign,
      required: { campaign_id: :uuid, message_id: :uuid, source: :string },
      optional: { contact_id: :uuid, url: :string, clicked_at: :date }
    },
    'custom' => {
      category: :custom,
      required: {},
      optional: {}
    }
    }.tap { |defs| deep_freeze(defs) }

    # Sanity check at load time: every EVENT_NAME must have a schema entry.
    # Mirrors the TS-side assertCatalogCoversAllNames().
    missing = EvoFlow::EVENT_NAMES.reject { |name| DEFINITIONS.key?(name) }
    raise "EvoFlow::EventSchema::DEFINITIONS is missing entries: #{missing.join(', ')}" if missing.any?
  end
end
