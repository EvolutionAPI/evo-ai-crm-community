# frozen_string_literal: true

# Adds optional references from an inbox to a MessageTemplate for the greeting
# and out-of-office auto-replies (EVO-1235 [6.6]). Both nullable: when unset the
# legacy string columns (greeting_message / out_of_office_message) are used.
# No FK constraint — referenced templates may be global/soft-managed and the
# auto-reply must stay resilient if one is removed (the hook falls back to the
# string column on an unresolvable id).
class AddTemplateRefsToInboxes < ActiveRecord::Migration[7.1]
  def change
    add_column :inboxes, :greeting_message_template_id, :uuid, null: true
    add_column :inboxes, :out_of_office_message_template_id, :uuid, null: true
  end
end
