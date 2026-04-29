# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::SendOnWhatsappService' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::SendOnWhatsappService do
  subject(:service) { described_class.new(message: message) }

  let(:contact) { instance_double(Contact, id: 1, identifier: nil, phone_number: '+5511999999999') }
  let(:contact_inbox) { instance_double(ContactInbox, source_id: contact_inbox_source_id) }
  let(:channel) { instance_double(Channel::Whatsapp, provider: provider) }
  let(:inbox) { instance_double(Inbox, channel: channel) }
  let(:conversation) do
    instance_double(Conversation,
                    contact: contact,
                    contact_inbox: contact_inbox,
                    inbox: inbox,
                    additional_attributes: additional_attributes)
  end
  let(:message) { instance_double(Message, conversation: conversation, additional_attributes: nil) }

  describe '#determine_target_number_for_sending — group routing' do
    context 'when provider is evolution_go and conversation has a group chat id' do
      let(:provider) { 'evolution_go' }
      let(:contact_inbox_source_id) { '12345-9876@g.us' }
      let(:additional_attributes) { { 'evolution_go_chat_id' => '12345-9876@g.us' } }

      it 'returns the group JID as the recipient' do
        expect(service.send(:determine_target_number_for_sending)).to eq('12345-9876@g.us')
      end
    end

    context 'when provider is evolution and conversation has a group chat id' do
      let(:provider) { 'evolution' }
      let(:contact_inbox_source_id) { '99999-1111@g.us' }
      let(:additional_attributes) { { 'evolution_chat_id' => '99999-1111@g.us' } }

      it 'returns the group JID as the recipient' do
        expect(service.send(:determine_target_number_for_sending)).to eq('99999-1111@g.us')
      end
    end

    context 'when evolution_go has an individual conversation (no group chat id)' do
      let(:provider) { 'evolution_go' }
      let(:contact_inbox_source_id) { '5511999999999' }
      let(:additional_attributes) { { 'evolution_go_chat_id' => '5511999999999@s.whatsapp.net' } }

      it 'falls through to the existing 1:1 routing (does not return a group JID)' do
        result = service.send(:determine_target_number_for_sending)
        expect(result).not_to end_with('@g.us')
      end
    end

    context 'when evolution_go conversation has no additional_attributes at all' do
      let(:provider) { 'evolution_go' }
      let(:contact_inbox_source_id) { '5511999999999' }
      let(:additional_attributes) { nil }

      it 'falls through to the existing 1:1 routing without raising' do
        expect { service.send(:determine_target_number_for_sending) }.not_to raise_error
      end
    end

    context 'when provider is zapi (not in the group routing whitelist)' do
      let(:provider) { 'zapi' }
      let(:contact_inbox_source_id) { '5511999999999' }
      let(:additional_attributes) { { 'evolution_go_chat_id' => '99999-1111@g.us' } }

      it 'ignores the group hint for non-evolution providers (own branch handles routing)' do
        result = service.send(:determine_target_number_for_sending)
        expect(result).not_to end_with('@g.us')
      end
    end
  end
end
