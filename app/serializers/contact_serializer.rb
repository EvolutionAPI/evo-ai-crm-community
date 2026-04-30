# frozen_string_literal: true

# ContactSerializer - Optimized serialization for Contact resources
#
# This is a plain Ruby module (NOT ActiveModel::Serializer) designed to work
# directly with Oj for maximum performance. No intermediate layers.
#
# Usage:
#   ContactSerializer.serialize(@contact, include_contact_inboxes: true)
#   ContactSerializer.serialize_collection(@contacts, include_labels: true)
#
module ContactSerializer
  extend self

  # Serialize single Contact with optimized field selection
  #
  # @param contact [Contact] Contact to serialize
  # @param options [Hash] Serialization options
  # @option options [Boolean] :include_contact_inboxes Include contact_inboxes association
  # @option options [Boolean] :include_labels Include labels (default: true)
  # @option options [Boolean] :include_companies Include companies for person type
  # @option options [Boolean] :include_pipelines Include pipeline data
  #
  # @return [Hash] Serialized contact ready for Oj
  #
  def serialize(contact, include_contact_inboxes: false, include_labels: true, include_companies: false, include_pipelines: false)
    result = contact.as_json(
      only: [:id, :name, :type, :email, :phone_number, :identifier, :blocked,
             :availability_status, :tax_id, :website, :industry],
    )

    # Add computed fields
    result['additional_attributes'] = contact.additional_attributes || {}
    result['custom_attributes'] = contact.custom_attributes || {}
    result['thumbnail'] = contact.avatar_url.presence

    # Timestamps as integers (faster than ISO8601 strings)
    result['created_at'] = contact.created_at.to_i
    result['last_activity_at'] = contact.last_activity_at&.to_i

    # Conditionally include labels
    if include_labels
      result['labels'] = contact.labels.map do |tag|
        label = Label.find_by(title: tag.name)
        { name: tag.name, color: label&.color || '#1f93ff' }
      end
    end

    # Conditionally include contact_inboxes
    if include_contact_inboxes
      result['contact_inboxes'] = contact.contact_inboxes.select { |ci| ci.inbox.present? }.map do |ci|
        {
          source_id: ci.source_id,
          inbox: {
            id: ci.inbox.id,
            name: ci.inbox.name,
            channel_type: ci.inbox.channel_type
          }
        }
      end
    end

    # Conditionally include companies/persons
    if include_companies
      if contact.type == 'person'
        result['companies'] = contact.companies.map do |company|
          {
            id: company.id,
            name: company.name,
            type: company.type,
            email: company.email,
            phone_number: company.phone_number,
            thumbnail: company.avatar_url.presence
          }
        end
      elsif contact.type == 'company'
        result['persons'] = contact.comp_contacts.map do |person|
          {
            id: person.id,
            name: person.name,
            type: person.type,
            email: person.email,
            phone_number: person.phone_number,
            thumbnail: person.avatar_url.presence
          }
        end
        result['persons_count'] = contact.company_contacts.size
      end
    end

    # Conditionally include pipelines
    if include_pipelines
      result['pipelines'] = serialize_pipelines(contact)
    end

    result
  end

  # Serialize collection of Contacts
  # Uses Oj's optimized array handling
  #
  # @param contacts [Array<Contact>, ActiveRecord::Relation] Contacts to serialize
  # @param options [Hash] Same options as serialize method
  #
  # @return [Array<Hash>] Array of serialized contacts
  #
  def serialize_collection(contacts, **options)
    return [] unless contacts

    contacts.map { |contact| serialize(contact, **options) }
  end

  private

  # Serialize pipeline data for a contact
  def serialize_pipelines(contact)
    return [] unless contact

    conversation_ids = contact.conversations.pluck(:id)
    
    pipeline_items = PipelineItem
                       .includes(:pipeline, :pipeline_stage)
                       .where('contact_id = ? OR conversation_id IN (?)', contact.id, conversation_ids)

    pipeline_items.group_by(&:pipeline).map do |pipeline, items|
      item = items.first
      stage = item.pipeline_stage

      {
        pipeline: {
          id: pipeline.id,
          name: pipeline.name,
          pipeline_type: pipeline.pipeline_type
        },
        stage: {
          id: stage.id,
          name: stage.name,
          color: stage.color,
          position: stage.position,
          stage_type: stage.stage_type
        },
        item: {
          id: item.id,
          item_id: item.contact_id || item.conversation_id,
          type: item.lead? ? 'lead' : 'deal',
          entered_at: item.entered_at&.to_i || item.created_at.to_i,
          notes: item.custom_fields&.dig('notes')
        }
      }
    end
  end
end
