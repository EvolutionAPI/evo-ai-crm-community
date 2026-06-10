# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InboxSerializer do
  describe 'connection state fields (EVO-1674)' do
    let(:channel) do
      Channel::Whatsapp.new(
        phone_number: '+5511999990000',
        provider: 'evolution',
        provider_connection: { 'connection' => 'open' },
        provider_config: { 'api_url' => 'http://evolution.local', 'instance_name' => 'inst-1' }
      ).tap { |c| c.save!(validate: false) }
    end
    let(:inbox) { Inbox.create!(channel: channel, name: 'WA Inbox') }

    before do
      allow(channel).to receive(:reauthorization_required?).and_return(false)
    end

    it 'exposes connection_state, health_source, last_sync and reauthorization_required' do
      result = described_class.serialize(inbox)

      expect(result['connection_state']).to eq('connected')
      expect(result['health_source']).to eq('provider_event')
      expect(result['last_sync']).to eq(channel.updated_at.to_i)
      expect(result['reauthorization_required']).to be(false)
    end

    it 'reports error when the channel requires reauthorization' do
      allow(channel).to receive(:reauthorization_required?).and_return(true)

      result = described_class.serialize(inbox)

      expect(result['connection_state']).to eq('error')
      expect(result['reauthorization_required']).to be(true)
    end

    it 'degrades explicitly for channel types without health support' do
      api_channel = Channel::Api.create!
      api_inbox = Inbox.create!(channel: api_channel, name: 'API Inbox')

      result = described_class.serialize(api_inbox)

      expect(result['connection_state']).to eq('unknown')
      expect(result['health_source']).to eq('none')
    end

    it 'adds no secrets to the payload' do
      result = described_class.serialize(inbox)

      expect(result.keys).to include('connection_state', 'health_source', 'last_sync')
      expect(result.to_json).not_to include('admin_token')
    end
  end
end
