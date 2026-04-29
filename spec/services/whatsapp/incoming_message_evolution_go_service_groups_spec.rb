# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::EvolutionGoHandlers::MessagesUpsert (groups)' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::IncomingMessageEvolutionGoService do
  let(:channel) { instance_double(Channel::Whatsapp, provider: 'evolution_go') }
  let(:inbox) { instance_double(Inbox, id: 1, channel: channel) }
  let(:contact) { instance_double(Contact, id: 99, name: 'My Squad', identifier: '12345-9876@g.us', update!: true) }
  let(:contact_inbox) { instance_double(ContactInbox, id: 7, contact: contact, source_id: '12345-9876@g.us') }
  let(:builder) { instance_double(ContactInboxWithContactBuilder, perform: contact_inbox) }

  let(:service) { described_class.new(inbox: inbox, params: { event: 'Message', data: {} }) }

  let(:group_info) do
    {
      ID: 'msg-1',
      Chat: '12345-9876@g.us',
      Sender: '5511999999999@s.whatsapp.net',
      IsFromMe: false,
      IsGroup: true,
      PushName: 'Alice',
      Type: 'conversation',
      Timestamp: '2026-01-15T10:00:00Z'
    }
  end

  let(:individual_info) do
    {
      ID: 'msg-2',
      Chat: '5511888888888@s.whatsapp.net',
      Sender: '5511888888888@s.whatsapp.net',
      IsFromMe: false,
      IsGroup: false,
      PushName: 'Bob',
      Type: 'conversation',
      Timestamp: '2026-01-15T10:00:01Z'
    }
  end

  let(:group_data) do
    { groupData: { Name: 'My Squad', Subject: 'My Squad' } }
  end

  before do
    service.instance_variable_set(:@inbox, inbox)
    allow(ContactInboxWithContactBuilder).to receive(:new).and_return(builder)
  end

  describe '#set_contact (group branch)' do
    before do
      service.instance_variable_set(:@evolution_go_info, group_info)
      service.instance_variable_set(:@evolution_go_data, group_data)
    end

    it 'creates a contact keyed by the group JID (Chat), not by the participant Sender' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:source_id]).to eq('12345-9876@g.us')
        builder
      end
      service.send(:set_contact)
    end

    it 'uses the group subject from groupData as the contact name when present' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes]).to include(name: 'My Squad', identifier: '12345-9876@g.us')
        builder
      end
      service.send(:set_contact)
    end

    it 'falls back to a deterministic group name when groupData is missing' do
      service.instance_variable_set(:@evolution_go_data, {})
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes][:name]).to match(/WhatsApp Group/)
        builder
      end
      service.send(:set_contact)
    end

    it 'does not assign phone_number to a group contact' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes]).not_to have_key(:phone_number)
        builder
      end
      service.send(:set_contact)
    end

    it 'does not enqueue a profile picture fetch for groups (would fail with non-phone identifier)' do
      expect(service).not_to receive(:update_contact_profile_picture)
      service.send(:set_contact)
    end
  end

  describe '#set_contact (individual branch — regression guard)' do
    before do
      service.instance_variable_set(:@evolution_go_info, individual_info)
      service.instance_variable_set(:@evolution_go_data, {})
      allow(service).to receive_messages(update_contact_profile_picture: nil, update_contact_information: nil)
    end

    it 'still routes to the individual contact builder for non-group messages' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes]).to include(:phone_number)
        builder
      end
      service.send(:set_contact)
    end
  end

  describe '#message_content_attributes' do
    it 'includes the participant pushName as sender_name for group messages' do
      service.instance_variable_set(:@evolution_go_info, group_info)
      attrs = service.send(:message_content_attributes)
      expect(attrs[:sender_name]).to eq('Alice')
    end

    it 'omits sender_name for individual messages (regression guard)' do
      service.instance_variable_set(:@evolution_go_info, individual_info)
      attrs = service.send(:message_content_attributes)
      expect(attrs).not_to have_key(:sender_name)
    end
  end
end
