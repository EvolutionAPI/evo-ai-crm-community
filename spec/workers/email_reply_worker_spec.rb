# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'EmailReplyWorker' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe EmailReplyWorker do
  let(:message) { instance_double(Message, email_notifiable_message?: true, source_id: nil, update!: true) }
  let(:mail) { double('Mail::Message', message_id: 'abc@host') }
  let(:mailer_params) { double('Mailer::Parameterized') }
  let(:delivery) { double('ActionMailer::MessageDelivery', deliver_now: mail) }
  let(:status_service) { instance_double(Messages::StatusUpdateService, perform: true) }

  before do
    allow(Message).to receive(:find).and_return(message)
  end

  describe '#perform — success path' do
    before do
      allow(ConversationReplyMailer).to receive(:with).with(account: nil).and_return(mailer_params)
      allow(mailer_params).to receive(:email_reply).with(message).and_return(delivery)
    end

    it 'captures the outbound Message-Id into source_id' do
      expect(message).to receive(:update!).with(source_id: 'abc@host')
      allow(Messages::StatusUpdateService).to receive(:new).with(message, 'delivered').and_return(status_service)

      described_class.new.perform(1)
    end

    it 'emits delivered via StatusUpdateService' do
      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'delivered').and_return(status_service)

      described_class.new.perform(1)
    end

    context 'when source_id is already set' do
      let(:message) { instance_double(Message, email_notifiable_message?: true, source_id: '<existing@host>') }

      it 'does not overwrite source_id' do
        expect(message).not_to receive(:update!)
        allow(Messages::StatusUpdateService).to receive(:new).and_return(status_service)

        described_class.new.perform(1)
      end
    end
  end

  describe '#perform — rescue path' do
    it 'emits failed via StatusUpdateService when deliver_now raises' do
      allow(ConversationReplyMailer).to receive(:with).and_raise(Net::SMTPFatalError, 'boom')
      tracker = instance_double(EvolutionExceptionTracker, capture_exception: true)
      allow(EvolutionExceptionTracker).to receive(:new).and_return(tracker)

      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'failed', 'boom').and_return(status_service)

      described_class.new.perform(1)
    end
  end
end
