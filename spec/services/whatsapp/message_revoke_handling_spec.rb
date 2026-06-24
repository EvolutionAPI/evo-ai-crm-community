# frozen_string_literal: true

require 'rails_helper'

# EVO-1748 (empty bubble) + EVO-1890 (inbound revoke notice): a WhatsApp
# delete-for-everyone arrives via evolution_go as a protocolMessage. It must NOT
# be created as a (empty) message, and the original must be marked
# revoked_by_contact so the agent sees a notice while keeping the content.
RSpec.describe 'WhatsApp revoke handling (EVO-1748 / EVO-1890)' do
  let(:channel) { instance_double(Channel::Whatsapp, provider: 'evolution_go') }
  let(:inbox) { instance_double(Inbox, id: 1, channel: channel) }
  let(:service) { Whatsapp::IncomingMessageEvolutionGoService.new(inbox: inbox, params: { event: 'Message', data: {} }) }

  before { service.instance_variable_set(:@inbox, inbox) }

  describe '#protocol_message?' do
    it 'is true for a revoke/protocol message' do
      service.instance_variable_set(:@evolution_go_message, { protocolMessage: { type: 'REVOKE', key: { id: 'X' } } })
      expect(service.send(:protocol_message?)).to be(true)
    end

    it 'is false for a normal text message' do
      service.instance_variable_set(:@evolution_go_message, { conversation: 'hello' })
      expect(service.send(:protocol_message?)).to be(false)
    end
  end

  describe 'revoke handling via #handle_message' do
    before { service.instance_variable_set(:@evolution_go_message, { protocolMessage: { type: 'REVOKE', key: { id: 'ABC' } } }) }

    it 'does not create a message and marks the original revoked_by_contact' do
      original = double('Message', id: 9, revoked_by_contact: false, incoming?: true)
      messages = double('messages')
      allow(inbox).to receive(:messages).and_return(messages)
      allow(messages).to receive(:find_by).with(source_id: 'ABC').and_return(original)

      expect(service).not_to receive(:message_processable?)
      expect(original).to receive(:revoked_by_contact=).with(true)
      expect(original).to receive(:save!)

      service.send(:handle_message)
    end

    it 'is a no-op (no empty message) when the original is not found' do
      messages = double('messages')
      allow(inbox).to receive(:messages).and_return(messages)
      allow(messages).to receive(:find_by).and_return(nil)

      expect(service).not_to receive(:message_processable?)
      expect { service.send(:handle_message) }.not_to raise_error
    end
  end

  describe '#revoked_message_source_id' do
    it 'extracts the key id (camelCase or capitalized)' do
      expect(service.send(:revoked_message_source_id, { key: { id: 'X1' } })).to eq('X1')
      expect(service.send(:revoked_message_source_id, { Key: { ID: 'X2' } })).to eq('X2')
    end
  end

  describe 'evolution provider messages.delete (the real revoke path for Baileys/evolution)' do
    let(:ev_channel) { instance_double(Channel::Whatsapp, provider: 'evolution') }
    let(:ev_inbox) { instance_double(Inbox, id: 1, channel: ev_channel) }
    let(:ev_service) do
      Whatsapp::IncomingMessageEvolutionService.new(
        inbox: ev_inbox,
        params: { event: 'messages.delete', data: { id: 'MID', remoteJid: '5511@s.whatsapp.net', fromMe: false, status: 'DELETED' } }
      )
    end

    it 'marks the deleted message revoked_by_contact' do
      msg = double('Message', id: 7, revoked_by_contact: false, incoming?: true)
      messages = double('messages')
      allow(ev_inbox).to receive(:messages).and_return(messages)
      allow(messages).to receive(:find_by).with(source_id: 'MID').and_return(msg)

      expect(msg).to receive(:revoked_by_contact=).with(true)
      expect(msg).to receive(:save!)

      ev_service.perform
    end

    it 'does NOT mark an outgoing message (echo of our own delete / fromMe=true)' do
      outgoing = double('Message', id: 8, incoming?: false)
      messages = double('messages')
      allow(ev_inbox).to receive(:messages).and_return(messages)
      allow(messages).to receive(:find_by).with(source_id: 'MID').and_return(outgoing)

      expect(outgoing).not_to receive(:revoked_by_contact=)
      expect(outgoing).not_to receive(:save!)

      ev_service.perform
    end
  end
end
