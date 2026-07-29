# frozen_string_literal: true

require 'rails_helper'

# EVO-2250 story 2.4.
RSpec.describe AgentBot do
  describe '#webhook_data' do
    # The hash reaches Message#webhook_data when a bot is the sender, and the
    # webhook listener delivers that payload to URLs the CUSTOMER registered.
    # The bot secret used to travel to third-party endpoints with it.
    it 'never carries the bot secret' do
      bot = described_class.new(
        name: 'Bot',
        outgoing_url: 'https://exemplo.test/webhook',
        api_key: 'chave-secreta'
      )

      payload = bot.webhook_data

      expect(payload).not_to have_key(:api_key)
      expect(payload.values.map(&:to_s)).not_to include('chave-secreta')
      expect(payload[:outgoing_url]).to eq('https://exemplo.test/webhook')
    end
  end
end
