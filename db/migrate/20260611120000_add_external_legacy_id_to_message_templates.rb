# frozen_string_literal: true

# EVO-1234 [6.5]: provenance + idempotency key for templates ported from the
# channel-coupled records into the global/independent (channel-less) flow.
# The partial unique index gives DB-level rerun safety: a second migration run
# can never insert a duplicate global counterpart for the same source row.
class AddExternalLegacyIdToMessageTemplates < ActiveRecord::Migration[7.1]
  def change
    add_column :message_templates, :external_legacy_id, :string

    add_index :message_templates, :external_legacy_id,
              unique: true,
              where: 'external_legacy_id IS NOT NULL',
              name: 'idx_message_templates_external_legacy_id'
  end
end
