# This file is used to render conversation data search API response.

json.id conversation.id.to_s
json.display_id conversation.display_id
json.uuid conversation.uuid
json.created_at conversation.created_at.to_i
pii_masked = ContactPiiMasker.should_mask?
json.contact do
  json.id conversation.contact.id
  json.name pii_masked ? ContactPiiMasker.mask_phone_like_name(conversation.contact.name) : conversation.contact.name
end
json.inbox do
  json.id conversation.inbox.id
  json.name conversation.inbox.name
  json.channel_type conversation.inbox.channel_type
end
json.messages do
  json.array! conversation.messages do |message|
    json.content message.content
    json.id message.id
    if message.sender
      contact_sender = message.sender_type.to_s.casecmp('contact').zero?
      json.sender_name (pii_masked && contact_sender) ? ContactPiiMasker.mask_phone_like_name(message.sender.name) : message.sender.name
    end
    json.message_type message.message_type_before_type_cast
    json.created_at message.created_at.to_i
  end
end

