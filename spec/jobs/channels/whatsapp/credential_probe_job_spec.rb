# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Channels::Whatsapp::CredentialProbeJob, type: :job do
  def graph_returns(status, body)
    stub_request(:get, /graph\.facebook\.com/)
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end

  def revoked_token
    graph_returns(400, '{"error":{"code":190,"message":"Invalid OAuth access token"}}')
  end

  def resolved_state(channel)
    Channels::ConnectionStateResolver.call(channel.reload)[:state]
  end

  let(:channel) do
    Channel::Whatsapp.create!(provider: 'whatsapp_cloud', phone_number: '+5511911110001',
                              provider_config: { 'api_key' => 'valid', 'waba_id' => '1' })
  end

  before do
    stub_request(:any, /graph\.facebook\.com/).to_return(status: 200, body: '{"data":[]}')
    channel.reauthorized!
  end

  # The reauthorization flag and its counter live in Redis, which no
  # transaction rolls back.
  after { channel.reauthorized! }

  describe '#perform' do
    it 'refreshes the stamp when the credential still works' do
      travel_to(3.days.from_now) do
        graph_returns(200, '{"data":[]}')

        described_class.perform_now(channel)

        expect(Time.zone.parse(channel.reload.provider_connection['credentials_verified_at']))
          .to be_within(1.minute).of(Time.current)
      end
    end

    # The credential is revoked at Meta between two runs of the job: nothing in
    # the CRM changed, so only a fresh probe can notice.
    it 'reports a credential revoked between two runs as an error, not as silence' do
      described_class.perform_now(channel)
      expect(resolved_state(channel)).to eq('connected')

      revoked_token
      described_class.perform_now(channel)

      expect(resolved_state(channel)).to eq('error')
    end

    # 'unknown' says nobody looked. We looked, and the provider said no.
    it 'does not erase the stamp on a rejected probe' do
      revoked_token

      described_class.perform_now(channel)

      expect(channel.reload.provider_connection).to have_key('credentials_verified_at')
    end

    it 'prompts reauthorization once rejections cross the threshold' do
      revoked_token

      Channel::Whatsapp::AUTHORIZATION_ERROR_THRESHOLD.times { described_class.perform_now(channel) }

      expect(channel.reauthorization_required?).to be(true)
    end

    # A 500 is the provider being unavailable, not the provider revoking a
    # credential. Counting it would turn any outage lasting two cycles into a
    # mass disconnect e-mail for every token channel in the install.
    it 'does not condemn the channel when the provider is merely unavailable' do
      graph_returns(500, '{}')

      2.times { described_class.perform_now(channel) }

      expect(resolved_state(channel)).to eq('connected')
      expect(channel.authorization_error_count).to eq(0)
      expect(channel.reauthorization_required?).to be(false)
    end

    it 'treats a rate limit as inconclusive, not as a revocation' do
      graph_returns(429, '{"error":{"code":4,"message":"Application request limit reached"}}')

      described_class.perform_now(channel)

      expect(resolved_state(channel)).to eq('connected')
      expect(channel.authorization_error_count).to eq(0)
    end

    # Without this the channel never leaves the head of the scheduler's queue:
    # it stays due forever and starves every healthy channel behind it.
    it 'records the attempt even when the probe tells us nothing' do
      graph_returns(500, '{}')

      described_class.perform_now(channel)

      expect(channel.reload.provider_connection['credentials_probed_at']).to be_present
    end

    it 'records the attempt when the provider rejects the credential' do
      revoked_token

      described_class.perform_now(channel)

      expect(channel.reload.provider_connection['credentials_probed_at']).to be_present
    end

    it 'clears the rejection once the credential answers again' do
      revoked_token
      described_class.perform_now(channel)
      expect(resolved_state(channel)).to eq('error')

      graph_returns(200, '{"data":[]}')
      described_class.perform_now(channel)

      expect(resolved_state(channel)).to eq('connected')
      expect(channel.authorization_error_count).to eq(0)
    end

    # The counter is shared with PARTNER_REMOVED and media 401s, which this
    # probe cannot observe. Clearing it on every success would mean no signal
    # outside the probe ever reaches the threshold.
    it 'leaves a failure count raised elsewhere alone' do
      channel.authorization_error!
      graph_returns(200, '{"data":[]}')

      described_class.perform_now(channel)

      expect(channel.authorization_error_count).to eq(1)
    end

    it 'counts a probe that raises as inconclusive rather than dying' do
      stub_request(:get, /graph\.facebook\.com/).to_timeout

      expect { described_class.perform_now(channel) }.not_to raise_error
      expect(channel.authorization_error_count).to eq(0)
      expect(channel.reload.provider_connection['credentials_probed_at']).to be_present
    end
  end
end
