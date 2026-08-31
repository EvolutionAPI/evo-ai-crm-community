# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Channels::Whatsapp::CredentialProbeSchedulerJob, type: :job do
  let(:probed) { [] }

  before do
    stub_request(:any, /graph\.facebook\.com/).to_return(status: 200, body: '{"data":[]}')
    stub_request(:any, /360dialog\.io/).to_return(status: 200, body: '{}')
    stub_request(:any, /notificame/).to_return(status: 200, body: '{}')
    allow(Channels::Whatsapp::CredentialProbeJob).to receive(:perform_later) { |channel| probed << channel.id }
  end

  # Saved without validation so the save-time probe does not write a fresh
  # stamp over the one the example is testing.
  def channel(provider:, phone_number:, stamp: nil, provider_config: { 'api_key' => 'valid', 'waba_id' => '1' })
    record = Channel::Whatsapp.new(
      provider: provider,
      phone_number: phone_number,
      provider_config: provider_config,
      provider_connection: stamp.nil? ? {} : { 'credentials_verified_at' => stamp }
    )
    record.save!(validate: false)
    record
  end

  describe '#perform' do
    it 'enqueues a probe for a channel whose stamp is older than the interval' do
      stale = channel(provider: 'whatsapp_cloud', phone_number: '+5511900000001', stamp: 7.hours.ago.utc.iso8601)

      described_class.perform_now

      expect(probed).to eq([stale.id])
    end

    it 'leaves a channel probed inside the interval alone' do
      channel(provider: 'whatsapp_cloud', phone_number: '+5511900000002', stamp: 1.hour.ago.utc.iso8601)

      described_class.perform_now

      expect(probed).to be_empty
    end

    it 'enqueues a channel that was never probed' do
      unproven = channel(provider: 'whatsapp_cloud', phone_number: '+5511900000003')

      described_class.perform_now

      expect(probed).to eq([unproven.id])
    end

    # A stamp the resolver cannot read already answers `unknown`. If the batch
    # query skipped it, or blew up casting it, nothing would ever repair it.
    it 'enqueues a channel carrying an unreadable stamp instead of choking on it' do
      garbled = channel(provider: 'whatsapp_cloud', phone_number: '+5511900000004', stamp: 'sim, confia')

      expect { described_class.perform_now }.not_to raise_error
      expect(probed).to eq([garbled.id])
    end

    it 'covers notificame too, not just whatsapp_cloud' do
      notificame = channel(provider: 'notificame', phone_number: '+5511900000005',
                           provider_config: { 'api_token' => 'valid' })

      described_class.perform_now

      expect(probed).to eq([notificame.id])
    end

    it 'skips a hub-managed channel, which has no local credential to probe' do
      channel(provider: 'whatsapp_cloud', phone_number: '+5511900000006',
              provider_config: { 'evolution_hub' => { 'status' => 'active' } })

      described_class.perform_now

      expect(probed).to be_empty
    end

    it 'skips QR providers, whose state comes from connection events' do
      channel(provider: 'evolution', phone_number: '+5511900000007',
              provider_config: { 'api_url' => 'https://evo.test', 'instance_name' => 'i' })

      described_class.perform_now

      expect(probed).to be_empty
    end

    # 360dialog's probe is a POST that re-registers the webhook. Repeating it on
    # a schedule would be a write against the provider every hour.
    it 'skips 360dialog, whose probe is not a read-only request' do
      channel(provider: 'default', phone_number: '+5511900000008')

      described_class.perform_now

      expect(probed).to be_empty
    end

    it 'takes the oldest stamps first and stops at the batch ceiling' do
      stub_const('Limits::BULK_EXTERNAL_HTTP_CALLS_LIMIT', 2)
      never = channel(provider: 'whatsapp_cloud', phone_number: '+5511900000010')
      oldest = channel(provider: 'whatsapp_cloud', phone_number: '+5511900000011', stamp: 30.hours.ago.utc.iso8601)
      channel(provider: 'whatsapp_cloud', phone_number: '+5511900000012', stamp: 8.hours.ago.utc.iso8601)

      described_class.perform_now

      expect(probed).to eq([never.id, oldest.id])
    end

    # The window has to stay well inside the TTL: a channel that fell out of the
    # resolver's evidence window before the job got back to it would read
    # `unknown` while nothing is actually wrong with it.
    it 'schedules re-probes far more often than the evidence expires' do
      expect(described_class::PROBE_INTERVAL).to be < Channels::ConnectionStateResolver::CREDENTIALS_TTL
    end
  end
end
