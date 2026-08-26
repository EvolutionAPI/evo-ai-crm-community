# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActionCableListener do
  describe '#hub_channel_connection_changed' do
    let(:inbox) { instance_double(Inbox, id: 'inbox-1', channel_type: 'Channel::Whatsapp', blank?: false) }
    let(:event) do
      Events::Base.new(
        Events::Types::HUB_CHANNEL_CONNECTION_CHANGED,
        Time.zone.now,
        { inbox: inbox, connection_status: 'connected' }
      )
    end

    before do
      allow(User).to receive(:pluck).with(:pubsub_token).and_return(%w[tok-a tok-b tok-a])
      allow(described_class.instance).to receive(:single_tenant_account).and_return(nil)
      allow(ActionCableBroadcastJob).to receive(:perform_later)
    end

    it 'transmite inbox, tipo de canal e estado para os tokens da conta' do
      described_class.instance.hub_channel_connection_changed(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later) do |tokens, name, payload|
        expect(tokens).to contain_exactly('tok-a', 'tok-b')
        expect(name).to eq(Events::Types::HUB_CHANNEL_CONNECTION_CHANGED)
        expect(payload[:inbox_id]).to eq('inbox-1')
        expect(payload[:channel_type]).to eq('Channel::Whatsapp')
        expect(payload[:connection_status]).to eq('connected')
      end
    end

    it 'nao transmite evento sem inbox' do
      sem_inbox = Events::Base.new(Events::Types::HUB_CHANNEL_CONNECTION_CHANGED, Time.zone.now, { connection_status: 'connected' })

      described_class.instance.hub_channel_connection_changed(sem_inbox)

      expect(ActionCableBroadcastJob).not_to have_received(:perform_later)
    end
  end
end
