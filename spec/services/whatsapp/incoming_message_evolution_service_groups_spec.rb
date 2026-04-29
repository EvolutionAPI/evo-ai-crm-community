# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::EvolutionHandlers::MessagesUpsert (groups)' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::IncomingMessageEvolutionService do
  let(:channel) { instance_double(Channel::Whatsapp, provider: 'evolution') }
  let(:inbox) { instance_double(Inbox, id: 1, channel: channel) }
  let(:contact) { instance_double(Contact, id: 99, name: 'WhatsApp Group 9876', identifier: '12345-9876@g.us') }
  let(:contact_inbox) { instance_double(ContactInbox, id: 7, contact: contact, source_id: '12345-9876@g.us') }
  let(:builder) { instance_double(ContactInboxWithContactBuilder, perform: contact_inbox) }

  let(:service) { described_class.new(inbox: inbox, params: { event: 'messages.upsert', data: {} }) }

  let(:group_message_payload) do
    {
      key: { id: 'msg-1', remoteJid: '12345-9876@g.us', fromMe: false, participant: '5511999999999@s.whatsapp.net' },
      pushName: 'Alice',
      messageTimestamp: 1_700_000_000,
      message: { conversation: 'hi everyone' }
    }
  end

  let(:individual_message_payload) do
    {
      key: { id: 'msg-2', remoteJid: '5511888888888@s.whatsapp.net', fromMe: false },
      pushName: 'Bob',
      messageTimestamp: 1_700_000_001,
      message: { conversation: 'hey' }
    }
  end

  before do
    service.instance_variable_set(:@inbox, inbox)
    allow(ContactInboxWithContactBuilder).to receive(:new).and_return(builder)
  end

  describe '#message_processable?' do
    before do
      allow(service).to receive_messages(ignore_message?: false, find_message_by_source_id: false, message_under_process?: false)
    end

    it 'allows group JIDs (the previous filter dropped them silently)' do
      service.instance_variable_set(:@raw_message, group_message_payload)
      expect(service.send(:message_processable?)).to be true
    end

    it 'still allows user JIDs (regression guard for 1:1 chats)' do
      service.instance_variable_set(:@raw_message, individual_message_payload)
      expect(service.send(:message_processable?)).to be true
    end

    it 'still rejects unsupported JID types like newsletter' do
      service.instance_variable_set(:@raw_message, { key: { id: 'msg-x', remoteJid: '123@newsletter' } })
      expect(service.send(:message_processable?)).to be false
    end
  end

  describe '#set_contact (group branch)' do
    before { service.instance_variable_set(:@raw_message, group_message_payload) }

    it 'creates the contact keyed by the group JID, not by any participant' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:source_id]).to eq('12345-9876@g.us')
        expect(args[:inbox]).to eq(inbox)
        builder
      end
      service.send(:set_contact)
    end

    it 'sets contact identifier to the group JID and name to the fallback group subject' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes]).to include(
          identifier: '12345-9876@g.us',
          name: a_string_matching(/WhatsApp Group/)
        )
        builder
      end
      service.send(:set_contact)
    end

    it 'does not assign phone_number to the group contact (would fail Contact format validation)' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes]).not_to have_key(:phone_number)
        builder
      end
      service.send(:set_contact)
    end
  end

  describe '#conversation_params (group branch)' do
    before do
      service.instance_variable_set(:@contact, contact)
      service.instance_variable_set(:@contact_inbox, contact_inbox)
    end

    it 'tags additional_attributes.evolution_chat_id with the group JID' do
      service.instance_variable_set(:@raw_message, group_message_payload)
      params = service.send(:conversation_params)
      expect(params[:additional_attributes]).to eq(evolution_chat_id: '12345-9876@g.us')
    end

    it 'omits additional_attributes for individual conversations (regression guard)' do
      service.instance_variable_set(:@raw_message, individual_message_payload)
      params = service.send(:conversation_params)
      expect(params).not_to have_key(:additional_attributes)
    end
  end

  describe '#message_content_attributes (sender_name for groups)' do
    it 'attaches the participant push name as sender_name for group messages' do
      service.instance_variable_set(:@raw_message, group_message_payload)
      attrs = service.send(:message_content_attributes)
      expect(attrs[:sender_name]).to eq('Alice')
    end

    it 'does not attach sender_name for individual messages (regression guard)' do
      service.instance_variable_set(:@raw_message, individual_message_payload)
      attrs = service.send(:message_content_attributes)
      expect(attrs).not_to have_key(:sender_name)
    end
  end
end
