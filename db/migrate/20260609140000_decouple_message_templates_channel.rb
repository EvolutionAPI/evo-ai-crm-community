# frozen_string_literal: true

# EVO-1231 [6.2]: decouple message templates from channel so they can exist as
# global (channel-less) records. Channel link becomes optional; a partial unique
# index guarantees global template names are unique among channel-less rows.
class DecoupleMessageTemplatesChannel < ActiveRecord::Migration[7.1]
  def up
    change_column_null :message_templates, :channel_type, true
    change_column_null :message_templates, :channel_id, true

    add_index :message_templates, :name,
              unique: true,
              where: 'channel_id IS NULL',
              name: 'idx_message_templates_global_name'
  end

  def down
    # Restoring NOT NULL is impossible once global (channel-less) templates exist.
    if select_value('SELECT 1 FROM message_templates WHERE channel_id IS NULL LIMIT 1')
      raise ActiveRecord::IrreversibleMigration,
            'Cannot restore NOT NULL on message_templates.channel_*: global (channel-less) templates exist'
    end

    remove_index :message_templates, name: 'idx_message_templates_global_name'
    change_column_null :message_templates, :channel_id, false
    change_column_null :message_templates, :channel_type, false
  end
end
