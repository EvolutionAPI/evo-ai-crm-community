class AddEmailSignatureToChannelSendgrid < ActiveRecord::Migration[7.1]
  def change
    add_column :channel_sendgrid, :email_signature, :text
  end
end
