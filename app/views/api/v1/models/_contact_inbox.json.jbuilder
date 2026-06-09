json.source_id ContactPiiMasker.should_mask? ? ContactPiiMasker.mask_identifier(resource.source_id) : resource.source_id
if resource.inbox.present?
  json.inbox do
    json.partial! 'api/v1/models/inbox_slim', formats: [:json], resource: resource.inbox
  end
end
