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

  it 'no-ops LOUDLY when the bot no longer exists' do
    allow(AgentBots::HttpRequestService).to receive(:new)
    allow(Rails.logger).to receive(:warn)
    missing_id = SecureRandom.uuid

    described_class.perform_now(missing_id, payload)

    expect(AgentBots::HttpRequestService).not_to have_received(:new)
    expect(Rails.logger).to have_received(:warn).with(/#{missing_id}/)
  end

  # The default provider only started crossing ActiveJob serialization with this
  # change, and HttpRequestService documents what string-vs-symbol keys cost
  # there (random contextId -> the agent loses the conversation history).
  # webhook_data hands the listener SYMBOL keys, so prove the round-trip keeps
  # what the service reads reachable - and never raises SerializationError.
  it 'round-trips the listener payload through ActiveJob unchanged' do
    native = { event: 'message_created', message_type: 'incoming', conversation: { id: 'c-1' } }

    args = ActiveJob::Arguments.deserialize(ActiveJob::Arguments.serialize([agent_bot.id, native]))

    expect(args.first).to eq(agent_bot.id)
    expect(args.last[:event]).to eq('message_created')
    expect(args.last.dig(:conversation, :id)).to eq('c-1')
  end
end
