# frozen_string_literal: true

require 'rails_helper'

# EVO-1748: a WhatsApp revoke (delete-for-everyone) arrives via evolution_go as a
# protocolMessage. It must NOT be processed as a regular message (which produced an
# empty bubble). evolution v2 / baileys already skip protocol via ignore_message?.
RSpec.describe 'WhatsApp evolution_go protocol message handling (EVO-1748)' do
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

  describe '#handle_message with a protocol message' do
    before { service.instance_variable_set(:@evolution_go_message, { protocolMessage: { type: 'REVOKE', key: { id: 'X' } } }) }

    it 'skips it without creating a message (no empty bubble)' do
      expect(service).not_to receive(:message_processable?)
      expect(service).not_to receive(:create_message)
      service.send(:handle_message)
    end
  end
end
