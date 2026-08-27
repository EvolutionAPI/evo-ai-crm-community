# frozen_string_literal: true

require 'rails_helper'

# Provider dispatch of process_webhook_bot_event: the default provider must go
# through the async job (its round-trip includes model latency; inline it holds
# the listener thread for the whole duration), while the bot-runtime and
# webhook paths keep their existing behavior.
RSpec.describe AgentBotListener do
  let(:listener) { described_class.instance }
  let(:payload) { { event: 'message_created' } }
  let(:agent_bot) do
    instance_double(AgentBot, id: SecureRandom.uuid, outgoing_url: 'https://bot.example',
                              webhook_provider?: false, n8n_provider?: false)
  end

  before { allow(BotRuntime::Config).to receive(:enabled?).and_return(false) }

  it 'enqueues the async job for the default provider instead of calling inline' do
    allow(AgentBots::HttpRequestJob).to receive(:perform_later)
    allow(AgentBots::HttpRequestService).to receive(:new)

    listener.send(:process_webhook_bot_event, agent_bot, payload)

    expect(AgentBots::HttpRequestJob).to have_received(:perform_later).with(agent_bot.id, payload)
    expect(AgentBots::HttpRequestService).not_to have_received(:new)
  end

  it 'keeps the webhook provider on its own async job' do
    allow(agent_bot).to receive(:webhook_provider?).and_return(true)
    allow(AgentBots::WebhookJob).to receive(:perform_later)

    listener.send(:process_webhook_bot_event, agent_bot, payload)

    expect(AgentBots::WebhookJob).to have_received(:perform_later).with(agent_bot.outgoing_url, payload)
  end

  it 'keeps the bot-runtime delegation path untouched when enabled' do
    allow(BotRuntime::Config).to receive(:enabled?).and_return(true)
    allow(listener).to receive(:delegate_to_bot_runtime)
    allow(AgentBots::HttpRequestJob).to receive(:perform_later)

    listener.send(:process_webhook_bot_event, agent_bot, payload)

    expect(listener).to have_received(:delegate_to_bot_runtime).with(agent_bot, payload)
    expect(AgentBots::HttpRequestJob).not_to have_received(:perform_later)
  end

  it 'does nothing without an outgoing_url' do
    allow(agent_bot).to receive(:outgoing_url).and_return('')
    allow(AgentBots::HttpRequestJob).to receive(:perform_later)

    listener.send(:process_webhook_bot_event, agent_bot, payload)

    expect(AgentBots::HttpRequestJob).not_to have_received(:perform_later)
  end
end
