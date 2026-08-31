# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Channels::Whatsapp::CredentialProbeJob, type: :job do
  def graph_returns(status, body)
    stub_request(:get, /graph\.facebook\.com/).to_return(status: status, body: body)
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

      graph_returns(401, '{"error":{"code":190}}')
      Channel::Whatsapp::AUTHORIZATION_ERROR_THRESHOLD.times { described_class.perform_now(channel) }

      expect(resolved_state(channel)).to eq('error')
      expect(channel.reauthorization_required?).to be(true)
    end

    # 'unknown' says nobody looked. We looked, and the provider said no.
    it 'does not erase the stamp on a failed probe' do
      graph_returns(401, '{"error":{}}')

      Channel::Whatsapp::AUTHORIZATION_ERROR_THRESHOLD.times { described_class.perform_now(channel) }

      expect(channel.reload.provider_connection).to have_key('credentials_verified_at')
    end

    it 'tolerates a single failure without condemning the channel' do
      graph_returns(500, '{}')

      described_class.perform_now(channel)

      expect(resolved_state(channel)).to eq('connected')
      expect(channel.authorization_error_count).to eq(1)
    end

    # Without this, one stray failure a month accumulates until an untouched,
    # perfectly healthy channel trips the threshold.
    it 'clears a stray failure count once the credential answers again' do
      graph_returns(500, '{}')
      described_class.perform_now(channel)

      graph_returns(200, '{"data":[]}')
      described_class.perform_now(channel)

      expect(channel.authorization_error_count).to eq(0)
    end

    it 'counts a probe that raises as a failed probe rather than dying' do
      stub_request(:get, /graph\.facebook\.com/).to_timeout

      expect { described_class.perform_now(channel) }.not_to raise_error
      expect(channel.authorization_error_count).to eq(1)
    end
  end
end
