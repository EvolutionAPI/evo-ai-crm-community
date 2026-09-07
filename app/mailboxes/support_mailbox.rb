class SupportMailbox < ApplicationMailbox
  include IncomingEmailValidityHelper
  attr_accessor :channel, :inbox, :conversation, :processed_mail

  before_processing :find_channel,
                    :load_inbox,
                    :decorate_mail

  def process
    Rails.logger.info "Processing email #{mail.message_id} from #{original_sender_email} to #{mail.to} with subject #{mail.subject}"

    # Skip processing email if it belongs to any of the edge cases
    return unless incoming_email_from_valid_email?

    ActiveRecord::Base.transaction do
      find_or_create_contact
      find_or_create_conversation
      create_message
      add_attachments_to_message
    end
  end

  private

  def find_channel
    find_channel_with_to_mail if @channel.blank?

    raise 'Email channel/inbox not found' if @channel.nil?

    @channel
  end

  def find_channel_with_to_mail
    @channel = EmailChannelFinder.new(mail).perform
  end

  def load_inbox
    @inbox = @channel.inbox
  end

  def decorate_mail
    @processed_mail = MailPresenter.new(mail)
  end

  def find_conversation_by_in_reply_to
    return if in_reply_to.blank?

    Conversation.where("additional_attributes->>'in_reply_to' = ?", in_reply_to).first
  end

  def in_reply_to
    sanitize_mailbox_value(mail['In-Reply-To'].try(:value))
  end

  def original_sender_email
    sanitize_mailbox_value(@processed_mail.original_sender)&.downcase
  end

  def find_or_create_conversation
    @conversation = find_conversation_by_in_reply_to || ::Conversation.create!({
                                                                                 inbox_id: @inbox.id,
                                                                                 contact_id: @contact.id,
                                                                                 contact_inbox_id: @contact_inbox.id,
                                                                                 additional_attributes: {
                                                                                   in_reply_to: in_reply_to,
                                                                                   source: 'email',
                                                                                   mail_subject: sanitize_mailbox_value(@processed_mail.subject),
                                                                                   initiated_at: {
                                                                                     timestamp: Time.now.utc
                                                                                   }
                                                                                 }
                                                                               })
  end

  def find_or_create_contact
    @contact = @inbox.contacts.from_email(original_sender_email)
    if @contact.present?
      @contact_inbox = ContactInbox.find_by(inbox: @inbox, contact: @contact)
    else
      create_contact
    end
  end

  def identify_contact_name
    processed_mail.sender_name || processed_mail.from.first.split('@').first
  end
end
