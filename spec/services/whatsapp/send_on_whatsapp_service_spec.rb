# frozen_string_literal: true

require 'rails_helper'

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

  # EVO-1682: identifier is only a valid Evolution Go destination when it looks like
  # a number/JID; non-numeric identifiers (imported lead labels) must fall back to
  # phone_number / source_id instead of being sent as the recipient.
  describe '#determine_target_number_for_sending — evolution_go identifier validation' do
    let(:provider) { 'evolution_go' }
    let(:additional_attributes) { nil }

    context 'when identifier is a non-numeric imported label' do
      let(:contact) { instance_double(Contact, id: 1, identifier: 'samambaia-090', phone_number: '+5561993372804') }
      let(:contact_inbox_source_id) { '5561993372804' }

      it 'ignores the identifier and uses the cleaned phone_number' do
        expect(service.send(:determine_target_number_for_sending)).to eq('5561993372804')
      end
    end

    context 'when identifier is a @lid JID (Evolution Go SenderAlt)' do
      let(:contact) { instance_double(Contact, id: 1, identifier: '96426461769841@lid', phone_number: '+5561993372804') }
      let(:contact_inbox_source_id) { '5561993372804' }

      it 'uses the identifier' do
        expect(service.send(:determine_target_number_for_sending)).to eq('96426461769841@lid')
      end
    end

    context 'when identifier is a digits-only number' do
      let(:contact) { instance_double(Contact, id: 1, identifier: '5561993372804', phone_number: nil) }
      let(:contact_inbox_source_id) { 'whatever' }

      it 'uses the identifier' do
        expect(service.send(:determine_target_number_for_sending)).to eq('5561993372804')
      end
    end

    context 'when identifier is a number with a leading +' do
      let(:contact) { instance_double(Contact, id: 1, identifier: '+5561993372804', phone_number: nil) }
      let(:contact_inbox_source_id) { 'whatever' }

      it 'uses the identifier stripped of the leading + (consistent with the phone_number path)' do
        expect(service.send(:determine_target_number_for_sending)).to eq('5561993372804')
      end
    end

    context 'when identifier is a @s.whatsapp.net JID' do
      let(:contact) { instance_double(Contact, id: 1, identifier: '5561993372804@s.whatsapp.net', phone_number: nil) }
      let(:contact_inbox_source_id) { 'whatever' }

      it 'uses the identifier' do
        expect(service.send(:determine_target_number_for_sending)).to eq('5561993372804@s.whatsapp.net')
      end
    end

    context 'when identifier is a legacy group JID (hyphenated)' do
      let(:contact) { instance_double(Contact, id: 1, identifier: '553184455827-1593702061@g.us', phone_number: nil) }
      let(:contact_inbox_source_id) { 'whatever' }

      it 'uses the identifier' do
        expect(service.send(:determine_target_number_for_sending)).to eq('553184455827-1593702061@g.us')
      end
    end

    context 'when identifier is a non-numeric label with a JID suffix' do
      let(:contact) { instance_double(Contact, id: 1, identifier: 'samambaia-090@lid', phone_number: '+5561993372804') }
      let(:contact_inbox_source_id) { '5561993372804' }

      it 'rejects it and uses the cleaned phone_number' do
        expect(service.send(:determine_target_number_for_sending)).to eq('5561993372804')
      end
    end

    context 'when identifier has + signs in the middle' do
      let(:contact) { instance_double(Contact, id: 1, identifier: '55+61+993372804', phone_number: '+5561993372804') }
      let(:contact_inbox_source_id) { '5561993372804' }

      it 'rejects it and uses the cleaned phone_number' do
        expect(service.send(:determine_target_number_for_sending)).to eq('5561993372804')
      end
    end

    context 'when identifier is invalid, source_id is a @lid JID and phone_number is present' do
      let(:contact) { instance_double(Contact, id: 1, identifier: 'samambaia-090', phone_number: '+5561993372804') }
      let(:contact_inbox_source_id) { '96426461769841@lid' }

      it 'prefers the source_id JID over the phone_number (branch order)' do
        expect(service.send(:determine_target_number_for_sending)).to eq('96426461769841@lid')
      end
    end

    context 'when identifier is invalid and source_id is a @lid JID' do
      let(:contact) { instance_double(Contact, id: 1, identifier: 'samambaia-090', phone_number: nil) }
      let(:contact_inbox_source_id) { '96426461769841@lid' }

      it 'falls back to the source_id JID' do
        expect(service.send(:determine_target_number_for_sending)).to eq('96426461769841@lid')
      end
    end

    context 'when contact only has phone_number (no identifier)' do
      let(:contact) { instance_double(Contact, id: 1, identifier: nil, phone_number: '+5561993372804') }
      let(:contact_inbox_source_id) { '5561993372804' }

      it 'uses the cleaned phone_number' do
        expect(service.send(:determine_target_number_for_sending)).to eq('5561993372804')
      end
    end

    context 'when identifier is invalid and there is no phone_number' do
      let(:contact) { instance_double(Contact, id: 1, identifier: 'samambaia-090', phone_number: nil) }
      let(:contact_inbox_source_id) { '5561993372804' }

      it 'falls back to source_id as last resort' do
        expect(service.send(:determine_target_number_for_sending)).to eq('5561993372804')
      end
    end
  end

  # AC6: when the provider rejects a send, the failure path must
  # go through Messages::StatusUpdateService so that the canonical Wisper
  # :message_status_changed event is published. Previously these two sites
  # called message.update!(status: :failed, external_error: ...) directly,
  # bypassing the funnel entirely — EvoFlow never saw the message.failed.
  describe '#send_session_message — failure routes through StatusUpdateService' do
    let(:provider) { 'evolution_go' }
    let(:contact_inbox_source_id) { '5511999999999' }
    let(:additional_attributes) { { 'evolution_go_chat_id' => '5511999999999@s.whatsapp.net' } }
    let(:provider_service) do
      instance_double(Whatsapp::Providers::EvolutionGoService, last_delivery_error: nil)
    end

    before do
      allow(channel).to receive(:provider_service).and_return(provider_service)
      allow(message).to receive(:id).and_return(99)
      allow(message).to receive(:is_unsupported).and_return(nil)
    end

    it 'AC6: delegates failure to Messages::StatusUpdateService with external_error' do
      allow(provider_service).to receive(:send_message).and_return(false)
      status_service = instance_double(Messages::StatusUpdateService, perform: true)

      expect(Messages::StatusUpdateService).to receive(:new).with(
        message,
        'failed',
        'Delivery failed: provider returned an error response'
      ).and_return(status_service)
      expect(status_service).to receive(:perform)

      service.send(:send_session_message)
    end

    context 'when the provider is whatsapp_cloud and Meta rejects the send (CRM-358)' do
      let(:provider) { 'whatsapp_cloud' }
      let(:additional_attributes) { nil }
      let(:provider_service) do
        instance_double(Whatsapp::Providers::WhatsappCloudService,
                        last_delivery_error: '(#131008) Required parameter is missing')
      end

      it 'marks the message failed with the Meta reason (nil used to fall through as sent)' do
        allow(provider_service).to receive(:send_message).and_return(nil)
        status_service = instance_double(Messages::StatusUpdateService, perform: true)

        expect(Messages::StatusUpdateService).to receive(:new).with(
          message,
          'failed',
          '(#131008) Required parameter is missing'
        ).and_return(status_service)

        service.send(:send_session_message)
      end
    end
  end

  describe '#send_template_message — failure routes through StatusUpdateService' do
    let(:provider) { 'evolution_go' }
    let(:contact_inbox_source_id) { '5511999999999' }
    let(:additional_attributes) { nil }
    let(:provider_service) do
      instance_double(Whatsapp::Providers::EvolutionGoService, last_delivery_error: nil)
    end

    before do
      allow(service).to receive(:processable_channel_message_template).and_return(
        ['template_name', 'namespace', 'pt_BR', []]
      )
      allow(service).to receive(:determine_target_number_for_sending).and_return('5511999999999')
      allow(channel).to receive(:provider_service).and_return(provider_service)
      allow(message).to receive(:id).and_return(99)
      allow(message).to receive(:is_unsupported).and_return(nil)
    end

    it 'AC6: delegates template-send failure to Messages::StatusUpdateService' do
      allow(provider_service).to receive(:send_template).and_return(false)
      status_service = instance_double(Messages::StatusUpdateService, perform: true)

      expect(Messages::StatusUpdateService).to receive(:new).with(
        message,
        'failed',
        'Template delivery failed: provider returned an error response'
      ).and_return(status_service)

      service.send(:send_template_message)
    end

    context 'when the provider is whatsapp_cloud and Meta rejects the template (CRM-358)' do
      let(:provider) { 'whatsapp_cloud' }
      let(:provider_service) do
        instance_double(Whatsapp::Providers::WhatsappCloudService,
                        last_delivery_error: '(#131008) Required parameter is missing')
      end

      it 'marks the message failed with the Meta reason (the evidence case: sent + source_id NULL)' do
        allow(provider_service).to receive(:send_template).and_return(nil)
        status_service = instance_double(Messages::StatusUpdateService, perform: true)

        expect(Messages::StatusUpdateService).to receive(:new).with(
          message,
          'failed',
          '(#131008) Required parameter is missing'
        ).and_return(status_service)

        service.send(:send_template_message)
      end
    end
  end

  # CRM-358: exhaustive return-contract matrix — no provider return may fall
  # into a branchless void (the original bug).
  describe '#handle_send_result' do
    let(:provider) { 'whatsapp_cloud' }
    let(:contact_inbox_source_id) { '5511999999999' }
    let(:additional_attributes) { nil }
    let(:provider_service) do
      instance_double(Whatsapp::Providers::WhatsappCloudService,
                      last_delivery_error: '(#131008) Required parameter is missing')
    end

    before do
      allow(message).to receive(:id).and_return(99)
      allow(message).to receive(:is_unsupported).and_return(nil)
    end

    it 'persists a String id as source_id and marks nothing (happy path)' do
      expect(message).to receive(:update!).with(source_id: 'wamid.HBgL')
      expect(Messages::StatusUpdateService).not_to receive(:new)

      service.send(:handle_send_result, 'wamid.HBgL', provider_service, 'fallback')
    end

    it 'persists a numeric id as source_id (Z-API/Notificame JSON ids)' do
      expect(message).to receive(:update!).with(source_id: '12345')
      expect(Messages::StatusUpdateService).not_to receive(:new)

      service.send(:handle_send_result, 12_345, provider_service, 'fallback')
    end

    it 'treats a blank-String id as success without id (empty id field in a success shape)' do
      expect(message).not_to receive(:update!)
      expect(Messages::StatusUpdateService).not_to receive(:new)

      service.send(:handle_send_result, '', provider_service, 'fallback')
    end

    it 'treats true as success without id (Evolution/Go/Notificame contract)' do
      expect(message).not_to receive(:update!)
      expect(Messages::StatusUpdateService).not_to receive(:new)

      service.send(:handle_send_result, true, provider_service, 'fallback')
    end

    it 'skips a nil for a message the provider already flagged unsupported (EvolutionGo contract)' do
      allow(message).to receive(:is_unsupported).and_return(true)
      expect(Messages::StatusUpdateService).not_to receive(:new)

      service.send(:handle_send_result, nil, provider_service, 'fallback')
    end

    it 'still marks false failed even when the message carries the unsupported flag' do
      allow(message).to receive(:is_unsupported).and_return(true)
      status_service = instance_double(Messages::StatusUpdateService, perform: true)
      expect(Messages::StatusUpdateService).to receive(:new)
        .with(message, 'failed', '(#131008) Required parameter is missing')
        .and_return(status_service)

      service.send(:handle_send_result, false, provider_service, 'fallback')
    end

    it 'marks nil failed with the recorded provider reason' do
      status_service = instance_double(Messages::StatusUpdateService, perform: true)
      expect(Messages::StatusUpdateService).to receive(:new)
        .with(message, 'failed', '(#131008) Required parameter is missing')
        .and_return(status_service)

      service.send(:handle_send_result, nil, provider_service, 'fallback')
    end

    it 'marks false failed with the fallback reason when no reason was recorded' do
      no_reason = instance_double(Whatsapp::Providers::EvolutionService, last_delivery_error: nil)
      status_service = instance_double(Messages::StatusUpdateService, perform: true)
      expect(Messages::StatusUpdateService).to receive(:new)
        .with(message, 'failed', 'fallback')
        .and_return(status_service)

      service.send(:handle_send_result, false, no_reason, 'fallback')
    end
  end
end
