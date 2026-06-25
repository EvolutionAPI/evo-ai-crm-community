# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Channel::Whatsapp, type: :model do
  describe '#merge_evolution_go_global_config' do
    let(:base_config) do
      {
        'instance_name' => 'test-instance',
        'instance_uuid' => SecureRandom.uuid,
        'instance_token' => SecureRandom.uuid,
        'always_online' => true,
        'reject_call' => true,
        'read_messages' => true,
        'ignore_groups' => false,
        'ignore_status' => true
      }
    end

    context 'when GlobalConfig has api_url and admin_token and provider_config lacks them' do
      it 'merges api_url and admin_token from GlobalConfig before validation' do
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_API_URL', '').and_return('http://evo.example.com')
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', '').and_return('secret-token')

        channel = described_class.new(provider: 'evolution_go', provider_config: base_config)
        channel.valid?

        expect(channel.provider_config['api_url']).to eq('http://evo.example.com')
        expect(channel.provider_config['admin_token']).to eq('secret-token')
      end
    end

    context 'when provider_config already has api_url and admin_token' do
      it 'does not overwrite existing values' do
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_API_URL', '').and_return('http://global.example.com')
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', '').and_return('global-secret')

        config = base_config.merge('api_url' => 'http://explicit.example.com', 'admin_token' => 'explicit-token')
        channel = described_class.new(provider: 'evolution_go', provider_config: config)
        channel.valid?

        expect(channel.provider_config['api_url']).to eq('http://explicit.example.com')
        expect(channel.provider_config['admin_token']).to eq('explicit-token')
      end
    end

    context 'when GlobalConfig is empty and provider_config lacks api_url' do
      it 'leaves provider_config unchanged' do
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_API_URL', '').and_return('')
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', '').and_return('')

        channel = described_class.new(provider: 'evolution_go', provider_config: base_config)
        channel.valid?

        expect(channel.provider_config['api_url']).to be_nil
        expect(channel.provider_config['admin_token']).to be_nil
      end
    end

    context 'when provider is not evolution_go' do
      it 'does not call GlobalConfigService for evolution_go keys' do
        # Stub the Meta Graph API health check that whatsapp_cloud#validate_provider_config? issues.
        # Without this, the example makes a real outbound HTTP call and fails under WebMock.
        stub_request(:get, %r{https://graph\.facebook\.com/}).to_return(status: 200, body: '{"data":[]}')

        expect(GlobalConfigService).not_to receive(:load).with('EVOLUTION_GO_API_URL', anything)
        expect(GlobalConfigService).not_to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', anything)

        channel = described_class.new(provider: 'whatsapp_cloud', provider_config: {})
        channel.valid?
      end
    end
  end
end
