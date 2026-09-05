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

  describe '#mark_connected!' do
    it 'clears the reauthorization flag and resets provider_connection to open' do
      channel = described_class.new(provider: 'evolution')
      allow(channel).to receive(:reauthorization_required?).and_return(true)

      expect(channel).to receive(:reauthorized!)
      expect(channel).to receive(:update_provider_connection!).with({ 'connection' => 'open', 'error' => nil })

      channel.mark_connected!
    end

    it 'leaves the reauthorization flag alone when none is set' do
      channel = described_class.new(provider: 'evolution')
      allow(channel).to receive(:reauthorization_required?).and_return(false)

      expect(channel).not_to receive(:reauthorized!)
      expect(channel).to receive(:update_provider_connection!).with({ 'connection' => 'open', 'error' => nil })

      channel.mark_connected!
    end
  end

  describe 'credential probe stamp' do
    it 'records credentials_verified_at when the provider probe succeeds' do
      stub_request(:get, %r{https://graph\.facebook\.com/}).to_return(status: 200, body: '{"data":[]}')

      channel = described_class.new(provider: 'whatsapp_cloud', phone_number: '+5511999990001',
                                    provider_config: { 'api_key' => 'valid', 'waba_id' => '1' })

      expect(channel).to be_valid
      expect(channel.provider_connection['credentials_verified_at']).to be_present
    end

    it 'leaves the channel unstamped and invalid when the provider probe fails' do
      stub_request(:get, %r{https://graph\.facebook\.com/}).to_return(status: 401, body: '{"error":{}}')

      channel = described_class.new(provider: 'whatsapp_cloud', phone_number: '+5511999990002',
                                    provider_config: { 'api_key' => 'revoked', 'waba_id' => '1' })

      expect(channel).not_to be_valid
      expect(channel.errors[:provider_config]).to include('Invalid Credentials')
      expect(channel.provider_connection).not_to have_key('credentials_verified_at')
    end

    # Re-saving with fresh credentials has to bring the channel back right
    # away; waiting for the next scheduled probe would leave it reading error
    # for up to six hours after the admin fixed it.
    it 'clears a rejection recorded by the probe when the credentials are re-saved' do
      stub_request(:get, %r{https://graph\.facebook\.com/}).to_return(status: 200, body: '{"data":[]}')

      channel = described_class.new(provider: 'whatsapp_cloud', phone_number: '+5511999990009',
                                    provider_config: { 'api_key' => 'valid', 'waba_id' => '1' },
                                    provider_connection: { 'credentials_rejected_at' => 1.hour.ago.utc.iso8601 })

      expect(channel).to be_valid
      expect(channel.provider_connection).not_to have_key('credentials_rejected_at')
    end

    it 'does not stamp a hub-managed channel, whose state comes from the Hub' do
      channel = described_class.new(provider: 'whatsapp_cloud', phone_number: '+5511999990003',
                                    provider_config: { 'evolution_hub' => { 'status' => 'pending' } })

      expect(channel).to be_valid
      expect(channel.provider_connection).not_to have_key('credentials_verified_at')
    end

    it 'persists the stamp through create!, which is what the resolver reads' do
      stub_request(:get, %r{https://graph\.facebook\.com/}).to_return(status: 200, body: '{"data":[]}')

      channel = described_class.create!(provider: 'whatsapp_cloud', phone_number: '+5511999990004',
                                        provider_config: { 'api_key' => 'valid', 'waba_id' => '1' })

      expect(channel.reload.provider_connection['credentials_verified_at']).to be_present
      expect(Channels::ConnectionStateResolver.call(channel.reload)[:state]).to eq('connected')
    end

    it 'keeps the stamp when an unrelated connection event replaces the snapshot' do
      stub_request(:get, %r{https://graph\.facebook\.com/}).to_return(status: 200, body: '{"data":[]}')

      channel = described_class.create!(provider: 'whatsapp_cloud', phone_number: '+5511999990005',
                                        provider_config: { 'api_key' => 'valid', 'waba_id' => '1' })
      channel.update_provider_connection!(connection: 'open', error: nil)

      expect(channel.reload.provider_connection['credentials_verified_at']).to be_present
      expect(channel.provider_connection['connection']).to eq('open')
    end

    # POST /inboxes/:id/disconnect_channel_provider always writes
    # connection: 'close' in its ensure block. Carrying the stamp past that
    # would keep the channel the operator just disconnected on 'connected'.
    it 'drops the stamp when the snapshot says the connection closed' do
      stub_request(:get, %r{https://graph\.facebook\.com/}).to_return(status: 200, body: '{"data":[]}')

      channel = described_class.create!(provider: 'whatsapp_cloud', phone_number: '+5511999990007',
                                        provider_config: { 'api_key' => 'valid', 'waba_id' => '1' })
      channel.update_provider_connection!(connection: 'close')

      expect(channel.reload.provider_connection).not_to have_key('credentials_verified_at')
      expect(Channels::ConnectionStateResolver.call(channel)[:state]).to eq('unknown')
    end
  end

  describe 'hub-managed channels' do
    it 'skips the local credential probe at every Hub status, including inactive' do
      channel = described_class.new(provider: 'whatsapp_cloud', phone_number: '+5511999990006',
                                    provider_config: { 'evolution_hub' => { 'status' => 'inactive' } })

      # provider_service builds a fresh instance per call, so pin the double the
      # validation will actually reach — otherwise the expectation is vacuous.
      service = instance_double(Whatsapp::Providers::WhatsappCloudService)
      allow(channel).to receive(:provider_service).and_return(service)
      expect(service).not_to receive(:validate_provider_config?)

      expect(channel).to be_valid
    end
  end
end
