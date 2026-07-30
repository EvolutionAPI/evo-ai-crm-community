# frozen_string_literal: true

# Read-only view over `evo_core_custom_tools`. Same arrangement as
# Ai::IntegrationCredential: the core owns the table, the CRM only reads it.
class Ai::CustomTool < ActiveRecord::Base # rubocop:disable Rails/ApplicationRecord -- write-path validations make no sense on a read-only view of a foreign table
  self.table_name = 'evo_core_custom_tools'

  scope :active, -> { where(is_active: true) }

  def readonly?
    true
  end
end
