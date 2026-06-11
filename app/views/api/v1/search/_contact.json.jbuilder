pii_masked = ContactPiiMasker.should_mask?
json.email pii_masked ? ContactPiiMasker.mask_email(contact.email) : contact.email
json.id contact.id
# EVO-1551 round 4: WhatsApp contacts arrive with the raw phone number as
# their `name` ("5511999..."). The search payload was leaking it because
# only the explicit phone/email/identifier fields were being masked here.
json.name pii_masked ? ContactPiiMasker.mask_phone_like_name(contact.name) : contact.name
json.phone_number pii_masked ? ContactPiiMasker.mask_phone(contact.phone_number) : contact.phone_number
json.identifier pii_masked ? ContactPiiMasker.mask_identifier(contact.identifier) : contact.identifier
