class AddCredentialIdToAgentBots < ActiveRecord::Migration[7.1]
  def change
    # A bot references ONE secret, so a scalar column is enough here. Tools and
    # MCPs need a map, because two auth headers are two credentials.
    #
    # No foreign key: the vault table belongs to evo-ai-core-service, which owns
    # its own migrations, and Rails does not manage that schema.
    add_column :agent_bots, :credential_id, :uuid, null: true
  end
end
