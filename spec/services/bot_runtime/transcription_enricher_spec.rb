# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::TranscriptionEnricher do
  subject(:enriched) { described_class.enrich(event) }

  let(:event) { { message_id: '42', message_content: 'oi' } }

  def audio_attachment(transcribed: nil)
    instance_double(Attachment, audio?: true, meta: transcribed ? { 'transcribed_text' => transcribed } : {})
  end

  def image_attachment
    instance_double(Attachment, audio?: false, meta: {})
  end

  def stub_message(attachments)
    message = instance_double(Message, attachments: attachments)
    allow(Message).to receive(:find_by).with(id: '42').and_return(message)
    message
  end

  it 'appends an existing transcription to the message content' do
    stub_message([audio_attachment(transcribed: 'quero dois produtos')])
    expect(enriched[:message_content]).to eq("oi\n\n[Transcrição do áudio]: quero dois produtos")
  end

  it 'uses only the transcript when the original content is blank (voice-only note)' do
    event[:message_content] = ''
    stub_message([audio_attachment(transcribed: 'bom dia')])
    expect(enriched[:message_content]).to eq('[Transcrição do áudio]: bom dia')
  end

  it 'transcribes on the spot when meta has no transcription yet' do
    stub_message([audio_attachment(transcribed: nil)])
    service = instance_double(Messages::AudioTranscriptionService, perform: { success: true, transcribed_text: 'olá' })
    allow(Messages::AudioTranscriptionService).to receive(:new).and_return(service)

    expect(enriched[:message_content]).to eq("oi\n\n[Transcrição do áudio]: olá")
    expect(Messages::AudioTranscriptionService).to have_received(:new)
  end

  it 'leaves the event unchanged when the message has no audio' do
    stub_message([image_attachment])
    expect(enriched).to eq(event)
  end

  it 'leaves the event unchanged when transcription fails/returns nothing' do
    stub_message([audio_attachment(transcribed: nil)])
    service = instance_double(Messages::AudioTranscriptionService, perform: { error: 'Transcription not enabled' })
    allow(Messages::AudioTranscriptionService).to receive(:new).and_return(service)
    expect(enriched).to eq(event)
  end

  it 'leaves the event unchanged when the message is not found' do
    allow(Message).to receive(:find_by).with(id: '42').and_return(nil)
    expect(enriched).to eq(event)
  end

  it 'leaves the event unchanged when there is no message_id' do
    expect(described_class.enrich({ message_content: 'oi' })).to eq({ message_content: 'oi' })
  end

  it 'is non-fatal: returns the event unchanged if anything raises' do
    allow(Message).to receive(:find_by).and_raise(StandardError, 'boom')
    expect(enriched).to eq(event)
  end
end
