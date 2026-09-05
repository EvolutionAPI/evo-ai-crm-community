# frozen_string_literal: true

require 'rails_helper'

# A channel the CRM created on the Hub is the CRM's to remove; a channel that
# was only LINKED stays the Hub's, and the CRM owns nothing but the webhook it
# added. Destroying the local record must not blur the two.
RSpec.describe EvolutionHubChannelCleanup do
  let(:client) { instance_double(EvolutionHub::Client) }

  before do
    allow(EvolutionHub::Client).to receive(:new).and_return(client)
    allow(client).to receive(:delete_webhook)
    allow(client).to receive(:delete_channel)
  end

  def whatsapp_channel(hub_block)
    Channel::Whatsapp.create!(
      phone_number: "+5511#{rand(10**9)}",
      provider: 'whatsapp_cloud',
      provider_config: { 'api_key' => '', 'phone_number_id' => '', 'evolution_hub' => hub_block }
    )
  end

  context 'when the channel was created by the CRM on the Hub' do
    let(:channel) do
      whatsapp_channel('channel_id' => 'hub-ch-1', 'webhook_id' => 'hub-wh-1', 'status' => 'pending')
    end

    it 'deletes the webhook and then the channel' do
      channel.destroy!

      expect(client).to have_received(:delete_webhook).with('hub-wh-1')
      expect(client).to have_received(:delete_channel).with('hub-ch-1')
    end
  end

  context 'when the channel was linked from the Hub' do
    let(:channel) do
      whatsapp_channel(
        'channel_id' => 'hub-ch-2', 'webhook_id' => 'hub-wh-2', 'status' => 'active', 'linked' => true
      )
    end

    it 'removes only the webhook and preserves the Hub channel' do
      channel.destroy!

      expect(client).to have_received(:delete_webhook).with('hub-wh-2')
      expect(client).not_to have_received(:delete_channel)
    end
  end

  context 'when the Hub rejects the cleanup' do
    let(:channel) do
      whatsapp_channel('channel_id' => 'hub-ch-3', 'webhook_id' => 'hub-wh-3', 'status' => 'pending')
    end

    it 'still destroys the local record' do
      allow(client).to receive(:delete_webhook).and_raise(
        EvolutionHub::Client::RequestError.new('boom', status: 500, body: '{}')
      )

      expect { channel.destroy! }.not_to raise_error
      expect(Channel::Whatsapp.exists?(channel.id)).to be(false)
    end
  end

  describe 'metadata readers' do
    it 'reads status and channel id from the WhatsApp provider_config shape' do
      channel = whatsapp_channel('channel_id' => 'hub-ch-4', 'status' => 'pending')

      expect(channel.evolution_hub_channel_id).to eq('hub-ch-4')
      expect(channel.evolution_hub_status).to eq('pending')
    end
  end
end
