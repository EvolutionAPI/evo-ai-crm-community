# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'BounceMailbox' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe BounceMailbox, type: :mailbox do
  let(:fixtures_dir) { Rails.root.join('spec/fixtures/files/email') }
  let(:permanent_eml) { fixtures_dir.join('dsn_permanent_bounce.eml').read }
  let(:transient_eml) { fixtures_dir.join('dsn_temp_failure.eml').read }
  let(:message) { instance_double(Message, id: 1, source_id: 'abc@host') }
  let(:status_service) { instance_double(Messages::StatusUpdateService, perform: true) }

  # Parse a fixture into a Mail::Message and invoke BounceMailbox directly,
  # bypassing ActionMailbox::InboundEmail's ActiveStorage attachment so tests
  # do not require active_storage_attachments wiring.
  def process_eml(source)
    inbound_mail = Mail.from_source(source)
    inbound = Struct.new(:mail).new(inbound_mail)
    mailbox = BounceMailbox.allocate
    mailbox.instance_variable_set(:@inbound_email, inbound)
    mailbox.define_singleton_method(:mail) { inbound_mail }
    mailbox.process
  end

  describe '#process' do
    context 'when DSN is permanent (5.x.x)' do
      it 'invokes StatusUpdateService with failed + diagnostic_code' do
        allow(Message).to receive(:find_by).with(source_id: 'abc@host').and_return(message)
        expect(Messages::StatusUpdateService)
          .to receive(:new).with(message, 'failed', '550 mailbox not found').and_return(status_service)

        process_eml(permanent_eml)
      end
    end

    context 'when DSN is transient (4.x.x)' do
      it 'does not invoke StatusUpdateService' do
        allow(Message).to receive(:find_by).with(source_id: 'abc@host').and_return(message)
        expect(Messages::StatusUpdateService).not_to receive(:new)

        process_eml(transient_eml)
      end
    end

    context 'when no Message matches Original-Message-ID' do
      it 'does not invoke StatusUpdateService and does not raise' do
        allow(Message).to receive(:find_by).with(source_id: 'abc@host').and_return(nil)
        expect(Messages::StatusUpdateService).not_to receive(:new)

        expect { process_eml(permanent_eml) }.not_to raise_error
      end
    end
  end

  describe 'routing order (AC18)' do
    let(:inbound_mail) { Mail.from_source(permanent_eml) }
    let(:inbound) { Struct.new(:mail).new(inbound_mail) }

    it 'routes a DSN sent to reply+UUID@ to BounceMailbox, NOT ReplyMailbox' do
      # The fixture's To: is `reply+6bdc3f4d-...@inbound.example.com` — would
      # match ReplyMailbox if the bounce route were absent or ordered after.
      # We exercise ApplicationMailbox.router.mailbox_for to pick the winning
      # mailbox from the registered routing chain.
      mailbox = ApplicationMailbox.router.mailbox_for(inbound)

      expect(mailbox).to eq(BounceMailbox)
    end

    it 'matches a multipart/report DSN-content message' do
      expect(ApplicationMailbox.delivery_status_notification?(inbound)).to be(true)
    end

    it 'sanity: the same DSN To: address WOULD match ReplyMailbox without the bounce route' do
      # Confirms the routing-order matters — the To: address is a reply+UUID@.
      expect(ApplicationMailbox.reply_uuid_mail?(inbound)).to be(true)
    end
  end
end
