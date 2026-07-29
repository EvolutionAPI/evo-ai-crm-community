# frozen_string_literal: true

# Read-only view over `evo_core_custom_tools` (EVO-2250, story 2.6).
#
# Same arrangement as Ai::IntegrationCredential: the table belongs to
# evo-ai-core-service (Go), which owns its migrations and every write, and both
# services share the `evo_community` database, so the migration reads it
# directly instead of going over HTTP.
#
# Not present in `db/schema.rb` on purpose — Rails does not own this table.
class Ai::CustomTool < ActiveRecord::Base # rubocop:disable Rails/ApplicationRecord -- write-path validations make no sense on a read-only view of a foreign table
  self.table_name = 'evo_core_custom_tools'

  scope :active, -> { where(is_active: true) }

  def readonly?
    true
  end
end
