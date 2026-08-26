# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBots::HttpRequestJob do
  let(:agent_bot) { AgentBot.create!(name: 'Bot', outgoing_url: 'https://bot.example') }
  let(:payload) { { 'event' => 'message_created', 'conversation' => { 'id' => 'c-1' } } }

  it 'runs the HTTP request service for the bot' do
    service = instance_double(AgentBots::HttpRequestService, perform: nil)
    allow(AgentBots::HttpRequestService).to receive(:new).and_return(service)

    described_class.perform_now(agent_bot.id, payload)

    expect(AgentBots::HttpRequestService).to have_received(:new).with(agent_bot, payload)
    expect(service).to have_received(:perform)
  end

  it 'no-ops when the bot no longer exists' do
    allow(AgentBots::HttpRequestService).to receive(:new)

    described_class.perform_now(SecureRandom.uuid, payload)

    expect(AgentBots::HttpRequestService).not_to have_received(:new)
  end
end
