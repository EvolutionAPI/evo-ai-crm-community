class AddWebhookRegistrationStatusToChannelSendgrid < ActiveRecord::Migration[7.1]
  def change
    add_column :channel_sendgrid, :webhook_registration_status, :string, null: false, default: 'pending'
  end
end
