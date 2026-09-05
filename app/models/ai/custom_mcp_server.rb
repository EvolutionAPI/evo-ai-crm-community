# frozen_string_literal: true

# Read-only view over `evo_core_custom_mcp_servers`.
# See Ai::CustomTool for why these views exist.
class Ai::CustomMcpServer < ActiveRecord::Base # rubocop:disable Rails/ApplicationRecord -- write-path validations make no sense on a read-only view of a foreign table
  self.table_name = 'evo_core_custom_mcp_servers'

  scope :active, -> { where(is_active: true) }

  def readonly?
    true
  end
end
