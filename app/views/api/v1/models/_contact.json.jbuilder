# Handle nil resource gracefully
if resource.present?
  pii_masked = ContactPiiMasker.should_mask?
  json.additional_attributes resource.additional_attributes
  json.availability_status resource.availability_status
  json.email pii_masked ? ContactPiiMasker.mask_email(resource.email) : resource.email
  json.id resource.id
  json.name pii_masked ? ContactPiiMasker.mask_phone_like_name(resource.name) : resource.name
  json.phone_number pii_masked ? ContactPiiMasker.mask_phone(resource.phone_number) : resource.phone_number
  json.blocked resource.blocked
  json.identifier pii_masked ? ContactPiiMasker.mask_identifier(resource.identifier) : resource.identifier
  json.thumbnail resource.avatar_url
  json.custom_attributes resource.custom_attributes
else
  # Fallback for nil resource
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
end
json.labels do
  if resource.present? && resource.labels.present?
    json.array! resource.labels do |tag|
      label = Label.find_by(title: tag.name)
      json.name tag.name
      json.color label&.color || '#1f93ff'
    end
  else
    json.array! []
  end
end
json.last_activity_at resource.present? && resource[:last_activity_at].present? ? resource.last_activity_at.to_i : nil
json.created_at resource.present? && resource[:created_at].present? ? resource.created_at.to_i : nil
# we only want to output contact inbox when its /contacts endpoints
if defined?(with_contact_inboxes) && with_contact_inboxes.present? && resource.present?
  json.contact_inboxes do
    json.array! resource.contact_inboxes do |contact_inbox|
      json.partial! 'api/v1/models/contact_inbox', formats: [:json], resource: contact_inbox
    end
  end
end
