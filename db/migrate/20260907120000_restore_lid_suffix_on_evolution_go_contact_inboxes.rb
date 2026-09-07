# frozen_string_literal: true

# Evolution Go addresses a contact that is absent from the account's address book
# by LID ("192234817380569@lid") instead of by phone. The ingest used to store the
# source_id as the bare user part, and a 15-digit LID is indistinguishable from an
# E.164 number once "@lid" is gone: on reply, Evolution Go's CreateJID rebuilt it as
# "<digits>@s.whatsapp.net" and WhatsApp refused it ("no LID found ... from server").
#
# The conversation kept the original JID in additional_attributes.evolution_go_chat_id,
# so it is the authority for deciding which rows were really LID-addressed. Rows whose
# source_id is a genuine phone number have no matching "<source_id>@lid" chat id and
# are left untouched.
class RestoreLidSuffixOnEvolutionGoContactInboxes < ActiveRecord::Migration[7.1]
  def up
    restore_source_ids
    backfill_identifiers
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Dropping the "@lid" server again would make the destination unroutable.'
  end

  private

  # The NOT EXISTS guard protects index_contact_inboxes_on_inbox_id_and_source_id
  # (unique): skip a row whose corrected source_id is already claimed in that inbox.
  # Keep SQL comments out of these heredocs — squish collapses them to one line and
  # a "--" would comment out every condition that follows it.
  def restore_source_ids
    restored = execute(<<~SQL.squish).cmd_tuples
      UPDATE contact_inboxes ci
      SET source_id = ci.source_id || '@lid'
      FROM conversations c
      WHERE c.contact_inbox_id = ci.id
        AND ci.source_id ~ '^[0-9]+$'
        AND c.additional_attributes->>'evolution_go_chat_id' = ci.source_id || '@lid'
        AND NOT EXISTS (
          SELECT 1 FROM contact_inboxes other
          WHERE other.inbox_id = ci.inbox_id
            AND other.source_id = ci.source_id || '@lid'
        )
    SQL

    say "contact_inboxes: #{restored} LID source_id(s) restored", true
  end

  # The outgoing echo (IsFromMe) looks the contact up by identifier against the
  # chat LID, so a LID contact without one silently drops its own sent messages.
  # The NOT EXISTS guard protects uniq_identifier_per_account_contact (unique).
  def backfill_identifiers
    identified = execute(<<~SQL.squish).cmd_tuples
      UPDATE contacts ct
      SET identifier = ci.source_id
      FROM contact_inboxes ci
      WHERE ci.contact_id = ct.id
        AND ct.identifier IS NULL
        AND ci.source_id LIKE '%@lid'
        AND NOT EXISTS (
          SELECT 1 FROM contacts other WHERE other.identifier = ci.source_id
        )
    SQL

    say "contacts: #{identified} LID identifier(s) backfilled", true
  end
end
