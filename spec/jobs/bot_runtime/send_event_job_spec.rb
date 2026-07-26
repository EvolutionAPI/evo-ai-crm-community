# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::SendEventJob do
  it 'enriches the event with the audio transcription before sending (EVO-2227)' do
    event = { conversation_id: '1', agent_bot_id: '2', message_id: '42', message_content: 'oi' }
    enriched = event.merge(message_content: "oi\n\n[Transcrição do áudio]: olá")
    allow(BotRuntime::TranscriptionEnricher).to receive(:enrich).with(event).and_return(enriched)

    client = instance_double(BotRuntime::Client, send_event: nil)
    allow(BotRuntime::Client).to receive(:new).and_return(client)

    described_class.new.perform(event)

    expect(client).to have_received(:send_event).with(enriched)
  end
end
