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
  def channel(provider:, phone_number:, connection: {}, provider_config: { 'api_key' => 'valid', 'waba_id' => '1' },
              inbox: true)
    record = Channel::Whatsapp.new(
      provider: provider,
      phone_number: phone_number,
      provider_config: provider_config,
      provider_connection: connection
    )
    record.save!(validate: false)
    Inbox.create!(name: "Inbox #{phone_number}", channel: record) if inbox
    record
  end

  def probed_at(stamp)
    { 'credentials_probed_at' => stamp }
  end

  describe '#perform' do
    it 'enqueues a probe for a channel whose last attempt is older than the interval' do
      stale = channel(provider: 'whatsapp_cloud', phone_number: '+5511900000001',
                      connection: probed_at(7.hours.ago.utc.iso8601))

      described_class.perform_now

      expect(probed).to eq([stale.id])
    end

    it 'leaves a channel probed inside the interval alone' do
      channel(provider: 'whatsapp_cloud', phone_number: '+5511900000002',
              connection: probed_at(1.hour.ago.utc.iso8601))

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
      garbled = channel(provider: 'whatsapp_cloud', phone_number: '+5511900000004',
                        connection: probed_at('sim, confia'))

      expect { described_class.perform_now }.not_to raise_error
      expect(probed).to eq([garbled.id])
    end

    # The resolver refuses a stamp in the future, so the channel reads unknown.
    # Skipping it here would leave that state with nothing to repair it.
    it 'enqueues a channel whose stamp sits in the future' do
      ahead = channel(provider: 'whatsapp_cloud', phone_number: '+5511900000013',
                      connection: probed_at(2.days.from_now.utc.iso8601))

      described_class.perform_now

      expect(probed).to eq([ahead.id])
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

    # A channel with no inbox has nobody to notify: the reauthorization mailer
    # builds its URL from the inbox and would raise on nil.
    it 'skips a channel with no inbox' do
      channel(provider: 'whatsapp_cloud', phone_number: '+5511900000009', inbox: false)

      described_class.perform_now

      expect(probed).to be_empty
    end

    it 'takes the oldest attempts first and stops at the batch ceiling' do
      stub_const('Limits::BULK_EXTERNAL_HTTP_CALLS_LIMIT', 2)
      never = channel(provider: 'whatsapp_cloud', phone_number: '+5511900000010')
      oldest = channel(provider: 'whatsapp_cloud', phone_number: '+5511900000011',
                       connection: probed_at(30.hours.ago.utc.iso8601))
      channel(provider: 'whatsapp_cloud', phone_number: '+5511900000012',
              connection: probed_at(8.hours.ago.utc.iso8601))

      described_class.perform_now

      expect(probed).to eq([never.id, oldest.id])
    end

    # The batch is picked by attempt, not by evidence. A channel the provider
    # keeps rejecting never refreshes credentials_verified_at, so ordering by
    # that stamp would park it at the head of every batch forever and starve
    # every healthy channel behind it.
    it 'does not let a channel the provider keeps rejecting hold a batch slot' do
      stub_const('Limits::BULK_EXTERNAL_HTTP_CALLS_LIMIT', 1)
      channel(provider: 'whatsapp_cloud', phone_number: '+5511900000014',
              connection: { 'credentials_verified_at' => 2.years.ago.utc.iso8601,
                            'credentials_rejected_at' => 5.minutes.ago.utc.iso8601,
                            'credentials_probed_at' => 5.minutes.ago.utc.iso8601 })
      healthy = channel(provider: 'whatsapp_cloud', phone_number: '+5511900000015',
                        connection: { 'credentials_verified_at' => 8.hours.ago.utc.iso8601,
                                      'credentials_probed_at' => 8.hours.ago.utc.iso8601 })

      described_class.perform_now

      expect(probed).to eq([healthy.id])
    end

    # The window has to stay well inside the TTL: a channel that fell out of the
    # resolver's evidence window before the job got back to it would read
    # `unknown` while nothing is actually wrong with it.
    it 'schedules re-probes far more often than the evidence expires' do
      expect(described_class::PROBE_INTERVAL).to be < Channels::ConnectionStateResolver::CREDENTIALS_TTL
    end
  end
end
