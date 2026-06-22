# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EvolutionHub::ChannelConnectedHandler do
  include ActiveJob::TestHelper

  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = original
  end

  let(:channel_uuid) { SecureRandom.uuid }
  let(:hub_channel_id) { 'hub-ch-abc' }
  let(:hub_channel_token) { 'hub-tok-xyz' }
  let(:waba_id) { '111122223333' }
  let(:phone_number_id) { '4444555566' }

  let(:base_provider_config) do
    {
      'api_key' => '',
      'phone_number_id' => '',
      'waba_id' => '',
      'evolution_hub' => { 'channel_id' => hub_channel_id, 'status' => 'pending' }
    }
  end

  let(:channel) do
    ch = Channel::Whatsapp.new(phone_number: "+5511#{rand(10**9)}", provider: 'whatsapp_cloud')
    ch.id = channel_uuid
    ch.provider_config = base_provider_config
    allow(ch).to receive(:new_record?).and_return(false)
    allow(ch).to receive(:persisted?).and_return(true)
    # Avoid touching the DB.
    allow(ch).to receive(:update!) do |attrs|
      ch.provider_config = attrs[:provider_config] if attrs.key?(:provider_config)
      true
    end
    allow(ch).to receive(:inbox).and_return(nil)
    ch
  end

  let(:payload) do
    {
      'external_id' => channel_uuid,
      'channel_id' => hub_channel_id,
      'channel_token' => hub_channel_token,
      'meta_connection' => {
        'access_token' => 'meta-access-token',
        'phone_number_id' => phone_number_id,
        'waba_id' => waba_id
      }
    }
  end

  before do
    allow(Channel::Whatsapp).to receive(:find_by).with(id: channel_uuid).and_return(channel)
    allow(Channel::FacebookPage).to receive(:find_by).and_return(nil)
    allow(Channel::Instagram).to receive(:find_by).and_return(nil)
  end

  describe '#perform — WhatsApp Cloud' do
    it 'writes credentials, flips hub status to active and enqueues TemplatesSyncJob' do
      expect do
        described_class.new(payload).perform
      end.to have_enqueued_job(Channels::Whatsapp::TemplatesSyncJob)

      enqueued = enqueued_jobs.last
      expect(enqueued[:job]).to eq(Channels::Whatsapp::TemplatesSyncJob)
      expect(enqueued[:args].first['_aj_globalid']).to include(channel_uuid)

      expect(channel.provider_config['api_key']).to eq('meta-access-token')
      expect(channel.provider_config['phone_number_id']).to eq(phone_number_id)
      expect(channel.provider_config['waba_id']).to eq(waba_id)
      expect(channel.provider_config.dig('evolution_hub', 'status')).to eq('active')
      expect(channel.provider_config.dig('evolution_hub', 'channel_token')).to eq(hub_channel_token)
    end

    it 'enqueues using hub channel_token when meta access_token is absent (Hub mode uses Bearer auth)' do
      payload['meta_connection'].delete('access_token')

      expect do
        described_class.new(payload).perform
      end.to have_enqueued_job(Channels::Whatsapp::TemplatesSyncJob)
    end

    it 'does not enqueue when api_key and channel_token are both absent' do
      payload['meta_connection'].delete('access_token')
      payload.delete('channel_token')
      allow(Rails.logger).to receive(:warn)
      allow(Rails.logger).to receive(:info)

      expect do
        described_class.new(payload).perform
      end.not_to have_enqueued_job(Channels::Whatsapp::TemplatesSyncJob)

      expect(Rails.logger).to have_received(:warn).with(/skipping template sync/).at_least(:once)
    end

    it 'does not enqueue the sync job when waba_id is missing (logs warning)' do
      payload['meta_connection'].delete('waba_id')
      allow(Rails.logger).to receive(:warn)
      allow(Rails.logger).to receive(:info)

      expect do
        described_class.new(payload).perform
      end.not_to have_enqueued_job(Channels::Whatsapp::TemplatesSyncJob)

      expect(Rails.logger).to have_received(:warn).with(/skipping template sync/).at_least(:once)
    end
  end

  describe '#perform — Facebook channel does not enqueue WhatsApp sync' do
    let(:fb_channel) do
      ch = Channel::FacebookPage.new(page_id: 'pg-1', user_access_token: 'old-token')
      allow(ch).to receive(:save!).and_return(true)
      allow(ch).to receive(:inbox).and_return(nil)
      ch
    end

    before do
      allow(Channel::Whatsapp).to receive(:find_by).with(id: channel_uuid).and_return(nil)
      allow(Channel::FacebookPage).to receive(:find_by).with(id: channel_uuid).and_return(fb_channel)
    end

    it 'does not enqueue TemplatesSyncJob' do
      fb_payload = {
        'external_id' => channel_uuid,
        'channel_id' => hub_channel_id,
        'channel_token' => hub_channel_token,
        'meta_connection' => { 'access_token' => 'fb-token' }
      }

      expect do
        described_class.new(fb_payload).perform
      end.not_to have_enqueued_job(Channels::Whatsapp::TemplatesSyncJob)
    end
  end
end
