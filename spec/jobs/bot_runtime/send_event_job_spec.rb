# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::SendEventJob do
  let(:client) { instance_double(BotRuntime::Client, send_event: nil) }

  before { allow(BotRuntime::Client).to receive(:new).and_return(client) }

  it 'forwards the message attachments AND the transcription before sending (EVO-2227)' do
    event = { conversation_id: '1', agent_bot_id: '2', message_id: '42', message_content: '' }
    attachments = [{ url: 'http://evo-crm:3000/rails/a1', content_type: 'audio/ogg', file_type: 'audio' }]
    allow(BotRuntime::AttachmentBuilder).to receive(:build).with('42').and_return(attachments)
    allow(BotRuntime::TranscriptionEnricher).to receive(:enrich) do |ev|
      ev.merge(message_content: '[Transcrição do áudio]: olá')
    end

    described_class.new.perform(event)

    expect(client).to have_received(:send_event).with(
      hash_including(attachments: attachments, message_content: '[Transcrição do áudio]: olá')
    )
  end

  it 'leaves the event untouched when the message has no attachments (text-only)' do
    event = { message_id: '42', message_content: 'oi' }
    allow(BotRuntime::AttachmentBuilder).to receive(:build).with('42').and_return([])
    allow(BotRuntime::TranscriptionEnricher).to receive(:enrich) { |ev| ev }

    described_class.new.perform(event)

    expect(client).to have_received(:send_event).with(event)
  end
end
