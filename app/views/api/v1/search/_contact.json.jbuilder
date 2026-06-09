pii_masked = ContactPiiMasker.should_mask?
json.email pii_masked ? ContactPiiMasker.mask_email(contact.email) : contact.email
json.id contact.id
json.name contact.name
json.phone_number pii_masked ? ContactPiiMasker.mask_phone(contact.phone_number) : contact.phone_number
json.identifier pii_masked ? ContactPiiMasker.mask_identifier(contact.identifier) : contact.identifier
