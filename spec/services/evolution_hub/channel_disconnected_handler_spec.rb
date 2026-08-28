# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe EvolutionHub::ChannelDisconnectedHandler do
  let(:channel_uuid) { SecureRandom.uuid }
  let(:inbox) { instance_double(Inbox, id: 77, channel_type: 'Channel::Whatsapp', blank?: false) }
  let(:dispatcher) { instance_double(Dispatcher, dispatch: true) }

  let(:channel) do
    ch = Channel::Whatsapp.new(phone_number: "+5511#{rand(10**9)}", provider: 'whatsapp_cloud')
    ch.id = channel_uuid
    ch.provider_config = { 'evolution_hub' => { 'channel_id' => 'hub-ch-abc', 'status' => 'active' } }
    allow(ch).to receive_messages(new_record?: false, persisted?: true, inbox: inbox)
    allow(ch).to receive(:update!) do |attrs|
      ch.provider_config = attrs[:provider_config] if attrs.key?(:provider_config)
      true
    end
    ch
  end

  let(:payload) { { 'external_id' => channel_uuid, 'channel_id' => 'hub-ch-abc' } }

  before do
    allow(Channel::Whatsapp).to receive(:find_by).with(id: channel_uuid).and_return(channel)
    allow(Channel::FacebookPage).to receive(:find_by).and_return(nil)
    allow(Channel::Instagram).to receive(:find_by).and_return(nil)
    allow(Rails.configuration).to receive(:dispatcher).and_return(dispatcher)
    allow(Rails.logger).to receive(:info)
  end

  it 'flips the hub status to inactive and announces the disconnection' do
    described_class.new(payload).perform

    expect(channel.provider_config.dig('evolution_hub', 'status')).to eq('inactive')
    expect(dispatcher).to have_received(:dispatch).with(
      Events::Types::HUB_CHANNEL_CONNECTION_CHANGED,
      kind_of(ActiveSupport::TimeWithZone),
      hash_including(inbox: inbox, connection_status: 'disconnected')
    )
  end

  it 'does not announce when no local channel matches the payload' do
    allow(Channel::Whatsapp).to receive(:find_by).with(id: channel_uuid).and_return(nil)
    allow(Rails.logger).to receive(:warn)

    described_class.new(payload).perform

    expect(dispatcher).not_to have_received(:dispatch)
  end

  # Persistence already happened; failing to tell the screen must not make the
  # Hub replay the webhook.
  it 'keeps the channel inactive when the announcement blows up' do
    allow(dispatcher).to receive(:dispatch).and_raise(StandardError, 'cable down')
    allow(Rails.logger).to receive(:error)

    expect { described_class.new(payload).perform }.not_to raise_error
    expect(channel.provider_config.dig('evolution_hub', 'status')).to eq('inactive')
  end

  # The examples above stub `update!`, so they cannot see a validation refusing
  # the write. A revoked Meta token is the most common reason the Hub sends
  # this event AND the reason a local credential probe would fail, so the
  # disconnection has to survive exactly that.
  describe 'against a persisted record, with the Meta credentials already revoked' do
    let!(:persisted) do
      # Credentials still good at creation time: the revocation comes after.
      stub_request(:get, %r{https://graph\.facebook\.com/}).to_return(status: 200, body: '{"data":[]}')
      Channel::Whatsapp.create!(
        phone_number: '+5511955550001',
        provider: 'whatsapp_cloud',
        provider_config: { 'api_key' => 'revoked', 'waba_id' => '1',
                           'evolution_hub' => { 'channel_id' => 'hub-real', 'status' => 'active' } }
      ).tap { |ch| Inbox.create!(channel: ch, name: 'WA Hub') }
    end

    before do
      allow(Channel::Whatsapp).to receive(:find_by).and_call_original
      stub_request(:get, %r{https://graph\.facebook\.com/}).to_return(status: 401, body: '{"error":{}}')
      # after_update_commit :subscribe re-posts subscribed_apps; production
      # swallows its failure, WebMock does not.
      stub_request(:post, %r{https://graph\.facebook\.com/}).to_return(status: 200, body: '{}')
    end

    it 'persists inactive and stops reporting the channel as connected' do
      expect { described_class.new('external_id' => persisted.id, 'channel_id' => 'hub-real').perform }
        .not_to raise_error

      expect(persisted.reload.provider_config.dig('evolution_hub', 'status')).to eq('inactive')
      expect(Channels::ConnectionStateResolver.call(persisted.reload)[:state]).to eq('disconnected')
    end
  end
end
