# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SyncMessageTemplateWithWhatsappCloudJob, type: :job do
  def whatsapp_channel(provider:)
    channel = Channel::Whatsapp.new(provider: provider, phone_number: "+1555#{SecureRandom.hex(3)}")
    channel.save!(validate: false)
    channel
  end

  let(:channel) { whatsapp_channel(provider: 'whatsapp_cloud') }
  let(:template) do
    t = MessageTemplate.new(
      name: "wac-#{SecureRandom.hex(4)}", content: 'Hi', category: 'UTILITY', language: 'pt_BR',
      components: [{ 'type' => 'BODY', 'text' => 'Hi' }]
    )
    allow(t).to receive(:channel).and_return(channel)
    t
  end

  it 'pushes the template to Meta via channel.create_template with the expected payload' do
    expect(channel).to receive(:create_template).with(
      hash_including(
        'name' => template.name,
        'category' => 'UTILITY',
        'language' => 'pt_BR',
        'components' => [{ 'type' => 'BODY', 'text' => 'Hi' }]
      )
    )

    described_class.new.perform(template)
  end

  it 'normalizes Hash-shaped components into Meta array form (adversarial review F2)' do
    template.components = { 'body' => { 'type' => 'BODY', 'text' => 'Hi' } }

    expect(channel).to receive(:create_template).with(
      hash_including('components' => [{ 'type' => 'BODY', 'text' => 'Hi' }])
    )

    described_class.new.perform(template)
  end

  it 'lands a pending status + external id on the same record (via the re-sync writeback)' do
    allow(channel).to receive(:create_template) do
      template.settings = { 'status' => 'PENDING' }
      template.metadata = { 'external_id' => '777' }
    end

    described_class.new.perform(template)

    expect(template.approval_status).to eq('pending')
    expect(template.external_template_id).to eq('777')
  end

  it 'skips and does not call create_template when the channel is not WhatsApp Cloud' do
    baileys = whatsapp_channel(provider: 'baileys')
    allow(template).to receive(:channel).and_return(baileys)

    expect(baileys).not_to receive(:create_template)

    expect { described_class.new.perform(template) }.not_to raise_error
  end

  it 'logs and does not re-raise when Meta publish fails (adversarial review F14)' do
    allow(channel).to receive(:create_template).and_raise(StandardError, 'meta down')

    expect(Rails.logger).to receive(:error).with(/sync failed/)
    expect { described_class.new.perform(template) }.not_to raise_error
  end
end
