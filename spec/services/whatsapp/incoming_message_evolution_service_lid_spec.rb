# frozen_string_literal: true

require 'rails_helper'

# Regression coverage for WhatsApp "LID addressing mode" on the Evolution path.
# When a 1:1 message arrives with remoteJid "<id>@lid" (2024+ privacy feature),
# jid_type returned 'lid', message_processable? rejected it, and the message was
# silently dropped. Evolution ships the real phone JID in remoteJidAlt, so we
# resolve it via effective_remote_jid. Refs evolution-foundation/evo-crm-community#49 (LID).
RSpec.describe Whatsapp::IncomingMessageEvolutionService do
  let(:channel) { instance_double(Channel::Whatsapp, provider: 'evolution') }
  let(:inbox) { instance_double(Inbox, id: 1, channel: channel) }
  let(:service) { described_class.new(inbox: inbox, params: { event: 'messages.upsert', data: {} }) }

  before do
    service.instance_variable_set(:@inbox, inbox)
    allow(service).to receive_messages(ignore_message?: false, find_message_by_source_id: false, message_under_process?: false)
  end

  context 'when a 1:1 message arrives in LID addressing mode' do
    let(:lid_payload) do
      {
        key: { id: 'msg-1', fromMe: false, addressingMode: 'lid',
               remoteJid: '256186830074110@lid', remoteJidAlt: '5511999999999@s.whatsapp.net' },
        pushName: 'Alice',
        message: { conversation: 'hello' }
      }
    end

    before { service.instance_variable_set(:@raw_message, lid_payload) }

    it 'resolves the JID type to user via remoteJidAlt (was dropped as lid)' do
      expect(service.send(:jid_type)).to eq('user')
    end

    it 'extracts the real phone number from remoteJidAlt, not the LID' do
      expect(service.send(:phone_number_from_jid)).to eq('5511999999999')
    end

    it 'is now processable instead of being silently dropped' do
      expect(service.send(:message_processable?)).to be true
    end
  end

  context 'when a LID message has no remoteJidAlt (cannot resolve)' do
    before do
      service.instance_variable_set(:@raw_message,
                                    { key: { id: 'msg-2', fromMe: false, remoteJid: '256186830074110@lid' },
                                      message: { conversation: 'hi' } })
    end

    it 'gracefully falls back to lid (no phantom @lid contact gets created)' do
      expect(service.send(:jid_type)).to eq('lid')
      expect(service.send(:message_processable?)).to be false
    end
  end

  context 'when a normal 1:1 message arrives (regression guard)' do
    before do
      service.instance_variable_set(:@raw_message,
                                    { key: { id: 'msg-3', fromMe: false, remoteJid: '5511888888888@s.whatsapp.net' },
                                      message: { conversation: 'hey' } })
    end

    it 'still classifies as user and extracts the phone unchanged' do
      expect(service.send(:jid_type)).to eq('user')
      expect(service.send(:phone_number_from_jid)).to eq('5511888888888')
    end
  end
end
