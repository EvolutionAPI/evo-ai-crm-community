# frozen_string_literal: true

require 'rails_helper'

# EVO-1891: agent deletes an outgoing message in the CRM -> propagate a
# delete-for-everyone to the provider (evolution-api).
RSpec.describe Whatsapp::Providers::EvolutionService do
  let(:channel) do
    instance_double(Channel::Whatsapp,
                    provider_config: { 'api_url' => 'http://localhost:8081', 'instance_name' => 'inst', 'admin_token' => 'tok' })
  end
  let(:service) { described_class.new(whatsapp_channel: channel) }

  describe '#delete_message' do
    let(:conversation) { double(contact_inbox: double(source_id: '5511999999999@s.whatsapp.net')) }
    let(:message) { double(source_id: 'MSGID123', outgoing?: true, conversation: conversation) }

    it 'calls deleteMessageForEveryone and returns true on success' do
      expect(HTTParty).to receive(:delete) do |url, opts|
        expect(url).to eq('http://localhost:8081/chat/deleteMessageForEveryone/inst')
        body = JSON.parse(opts[:body])
        expect(body).to include('id' => 'MSGID123', 'remoteJid' => '5511999999999@s.whatsapp.net', 'fromMe' => true)
        expect(opts[:headers]['apikey']).to eq('tok')
        double(success?: true, code: 200)
      end
      expect(service.delete_message(message)).to be(true)
    end

    it 'returns false on provider failure' do
      allow(HTTParty).to receive(:delete).and_return(double(success?: false, code: 400, body: 'err'))
      expect(service.delete_message(message)).to be(false)
    end

    it 'does not call the provider when source_id is blank' do
      blank = double(source_id: nil, outgoing?: true, conversation: conversation)
      expect(HTTParty).not_to receive(:delete)
      expect(service.delete_message(blank)).to be(false)
    end
  end

  describe '#remote_jid_for' do
    it 'keeps an existing jid as-is' do
      msg = double(conversation: double(contact_inbox: double(source_id: '12345-678@g.us')))
      expect(service.send(:remote_jid_for, msg)).to eq('12345-678@g.us')
    end

    it 'builds an s.whatsapp.net jid from a bare number' do
      msg = double(conversation: double(contact_inbox: double(source_id: '+5511999999999')))
      expect(service.send(:remote_jid_for, msg)).to eq('5511999999999@s.whatsapp.net')
    end
  end
end
