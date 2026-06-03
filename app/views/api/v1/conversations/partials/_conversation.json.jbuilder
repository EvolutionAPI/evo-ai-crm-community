# TODO: Move this into models jbuilder
# Currently the file there is used only for search endpoint.
# Everywhere else we use conversation builder in partials folder

json.meta do
  json.sender do
    if conversation.contact.present?
      json.partial! 'api/v1/models/contact', formats: [:json], resource: conversation.contact
    else
      # Handle orphaned conversations with missing contacts
      json.additional_attributes({})
      json.availability_status 'offline'
      json.email nil
      json.id nil
      json.name 'Unknown Contact'
      json.phone_number nil
      json.blocked false
      json.identifier nil
      json.thumbnail nil
      json.custom_attributes({})
      json.labels []
      json.last_activity_at nil
      json.created_at nil
    end
  end
  json.channel conversation.inbox&.channel_type
  if conversation.assignee.present?
    json.assignee do
      json.partial! 'api/v1/models/agent', formats: [:json], resource: conversation.assignee
    end
  end
  if conversation.team.present?
    json.team do
      json.partial! 'api/v1/models/team', formats: [:json], resource: conversation.team
    end
  end
  json.hmac_verified conversation.contact_inbox&.hmac_verified
end

json.id conversation.id.to_s
json.display_id conversation.display_id

# Optimize message loading to avoid N+1 queries
last_message = conversation.association(:messages).loaded? ?
  conversation.messages.last :
  conversation.messages.includes(:attachments).last

if last_message.blank?
  json.messages []
else
  json.messages [last_message.try(:push_event_data)]
end

json.uuid conversation.uuid
json.additional_attributes conversation.additional_attributes
json.agent_last_seen_at conversation.agent_last_seen_at.to_i
json.assignee_last_seen_at conversation.assignee_last_seen_at.to_i
json.can_reply conversation.can_reply?
json.contact_last_seen_at conversation.contact_last_seen_at.to_i
json.custom_attributes conversation.custom_attributes
json.inbox_id conversation.inbox_id
json.labels conversation.cached_label_list_array
json.muted conversation.muted?
json.snoozed_until conversation.snoozed_until
json.status conversation.status
json.created_at conversation.created_at.to_i
json.updated_at conversation.updated_at.to_f
json.timestamp conversation.last_activity_at.to_i
json.first_reply_created_at conversation.first_reply_created_at.to_i

unread_count = conversation.association(:messages).loaded? ?
  conversation.messages.count { |m| m.message_type == 'incoming' && !m.content_attributes['read'] } :
  conversation.unread_incoming_messages_count

json.unread_count unread_count

# Optimize last non-activity message to avoid N+1 queries
last_non_activity_message = conversation.association(:messages).loaded? ?
  conversation.messages.reject(&:activity?).first :
  conversation.messages.non_activity_messages.first

json.last_non_activity_message last_non_activity_message.try(:push_event_data)
json.last_activity_at conversation.last_activity_at.to_i
json.priority conversation.priority
json.waiting_since conversation.waiting_since.to_i.to_i

# Pipeline information - optimized to avoid N+1 queries
pipeline_item = if conversation.association(:pipeline_items).loaded?
  conversation.pipeline_items.first
else
  # Use preload instead of includes to avoid join issues
  conversation.pipeline_items.preload(:pipeline, :pipeline_stage, :stage_movements).first
end

if pipeline_item
  json.pipeline_item_id pipeline_item.id
  json.pipeline do
    json.id pipeline_item.pipeline.id
    json.name pipeline_item.pipeline.name
    json.pipeline_type pipeline_item.pipeline.pipeline_type
  end
  json.pipeline_stage do
    json.id pipeline_item.pipeline_stage.id
    json.name pipeline_item.pipeline_stage.name
    json.color pipeline_item.pipeline_stage.color
    json.position pipeline_item.pipeline_stage.position
    json.stage_type pipeline_item.pipeline_stage.stage_type
  end
  json.pipeline_info do
    json.entered_at pipeline_item.entered_at.to_i
    json.days_in_pipeline pipeline_item.days_in_pipeline
    json.days_in_current_stage pipeline_item.days_in_current_stage

    # Optimize stage_movements query
    last_movement = pipeline_item.association(:stage_movements).loaded? ?
      pipeline_item.stage_movements.max_by(&:created_at) :
      pipeline_item.stage_movements.order(:created_at).last

    json.notes last_movement&.notes
  end
end

