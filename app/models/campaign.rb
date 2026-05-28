class Campaign < ApplicationRecord
  # `campaigns.type` is a plain string column (not STI). Point AR's
  # inheritance_column at a non-existent column so the STI lookup is a no-op
  # and `find_by(id:)` works regardless of the row's `type` value. If a
  # future story introduces real STI (OngoingCampaign / OneOffCampaign),
  # revert this line and update the EvoFlow enrich path that depends on
  # Campaign.find_by.
  self.inheritance_column = :_type_disabled

  default_scope { where(deleted_at: nil) }
end
