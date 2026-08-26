# frozen_string_literal: true

require 'rails_helper'

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
end
