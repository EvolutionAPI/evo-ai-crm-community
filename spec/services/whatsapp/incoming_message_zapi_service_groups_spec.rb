# frozen_string_literal: true

require 'rails_helper'

# Regression coverage for the Z-API group path. Before this fix a group message was
# silently dropped (the WhatsappEventsJob rescue swallowed the error) by two validations:
#   1. phone_number: "+#{params[:phone]}" — params[:phone] is "<digits>-group", not E.164.
#   2. ContactInbox#source_id — "<digits>-group" fails the source-id regex, which for groups
#      expects "<digits>@g.us". The fix normalizes the Z-API group JID to that shape.
# Mirrors spec/services/whatsapp/incoming_message_evolution_service_groups_spec.rb.
RSpec.describe Whatsapp::IncomingMessageZapiService do
  let(:inbox) { instance_double(Inbox, id: 1) }
  let(:contact) { instance_double(Contact, id: 99, avatar: instance_double(ActiveStorage::Attached::One, attached?: true)) }
  let(:contact_inbox) { instance_double(ContactInbox, id: 7, contact: contact, contact_id: 99) }
  let(:builder) { instance_double(ContactInboxWithContactBuilder, perform: contact_inbox) }

  # Mirrors the real Z-API group payload: chatLid is nil and phone is the "<digits>-group" JID.
  let(:group_params) do
    {
      type: 'ReceivedCallback', fromMe: false, isGroup: true,
      phone: '120363403143464221-group', chatLid: nil,
      chatName: 'My Group', senderName: 'Alice', participantPhone: '5511999999999',
      messageId: 'msg-1', momment: 1_700_000_000_000, text: { message: 'hi everyone' }
    }
  end

  let(:individual_params) do
    {
      type: 'ReceivedCallback', fromMe: false, isGroup: false,
      phone: '5511888888888', chatName: 'Bob', senderName: 'Bob',
      messageId: 'msg-2', momment: 1_700_000_001_000, text: { message: 'hey' }
    }
  end

  before do
    allow(ContactInboxWithContactBuilder).to receive(:new).and_return(builder)
  end

  describe '#process_incoming_message (group branch)' do
    let(:service) { described_class.new(inbox: inbox, params: group_params) }

    before do
      allow(service).to receive(:find_or_create_conversation).and_return(instance_double(Conversation, id: 5))
      allow(service).to receive(:process_text_message)
      allow(service).to receive(:fetch_contact_profile_picture)
    end

    it 'normalizes the group JID to <digits>@g.us, builds a type group contact, no phone_number' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:source_id]).to eq('120363403143464221@g.us')
        expect(args[:contact_attributes]).to include(type: 'group', identifier: '120363403143464221@g.us')
        expect(args[:contact_attributes]).not_to have_key(:phone_number)
        builder
      end
      service.send(:process_incoming_message)
    end

    it 'does not try to fetch a profile picture for a group (no contact phone)' do
      expect(service).not_to receive(:fetch_contact_profile_picture)
      service.send(:process_incoming_message)
    end
  end

  describe '#process_incoming_message (individual branch, regression guard)' do
    let(:service) { described_class.new(inbox: inbox, params: individual_params) }

    before do
      allow(service).to receive(:find_or_create_conversation).and_return(instance_double(Conversation, id: 6))
      allow(service).to receive(:process_text_message)
      allow(service).to receive(:fetch_contact_profile_picture)
    end

    it 'still builds the contact with an E.164 phone_number and no group type' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes]).to include(phone_number: '+5511888888888')
        expect(args[:contact_attributes]).not_to have_key(:type)
        builder
      end
      service.send(:process_incoming_message)
    end
  end
end
