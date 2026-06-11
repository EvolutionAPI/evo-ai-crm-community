# frozen_string_literal: true

require 'rails_helper'

# EVO-1251 (story 9.4): outbound email for a Channel::Sendgrid inbox routes to
# Sendgrid::SendEmailWorker; Gmail/Outlook (Channel::Email) keep the SMTP path
# untouched (AC6, zero regression).
RSpec.describe Message do
  describe '#trigger_notify_via_mail SendGrid outbound dispatch' do
    let(:message) { described_class.new }

    before { allow(message).to receive(:id).and_return(7) }

    context 'when the inbox channel is SendGrid' do
      before { allow(message).to receive(:inbox).and_return(instance_double(Inbox, inbox_type: 'SendGrid')) }

      it 'enqueues Sendgrid::SendEmailWorker' do
        expect(Sendgrid::SendEmailWorker).to receive(:perform_in).with(1.second, 7)
        expect(EmailReplyWorker).not_to receive(:perform_in)

        message.send(:trigger_notify_via_mail)
      end
    end

    context 'when the inbox channel is Email (Gmail/Outlook)' do
      before { allow(message).to receive(:inbox).and_return(instance_double(Inbox, inbox_type: 'Email')) }

      it 'keeps the existing EmailReplyWorker path and never calls SendGrid' do
        expect(EmailReplyWorker).to receive(:perform_in).with(1.second, 7)
        expect(Sendgrid::SendEmailWorker).not_to receive(:perform_in)

        message.send(:trigger_notify_via_mail)
      end
    end
  end
end
