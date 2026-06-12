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

  # Production's writeback lands via TemplateSync#sync_template_to_database ->
  # find_or_initialize_by(channel:, name:, language:), i.e. on the DB record matched
  # by (channel, name, language) — NOT on the in-memory instance the job holds. So
  # we persist the template, have the stub write back through that SAME lookup (same
  # name/language so it resolves to the existing row, not a second one — review F8),
  # and assert on reload. (review F4 — the old mock mutated the in-memory instance
  # and gave false confidence.) Note: the external_id value is injected by the stub,
  # mirroring that the real sync copies metadata['external_id'] from Meta's payload;
  # this guards "writeback hit the right record", not Meta-id propagation itself (F11).
  it 'lands a pending status + external id on the persisted record (via the find_or_initialize_by writeback)' do
    persisted = MessageTemplate.create!(
      name: "wac-#{SecureRandom.hex(4)}", content: 'Hi', category: 'UTILITY',
      language: 'pt_BR', channel: channel, components: [{ 'type' => 'BODY', 'text' => 'Hi' }]
    )

    allow(channel).to receive(:create_template) do |payload|
      record = MessageTemplate.find_or_initialize_by(
        channel: channel, name: payload['name'], language: payload['language']
      )
      record.update!(settings: { 'status' => 'PENDING' }, metadata: { 'external_id' => '777' })
    end

    described_class.new.perform(persisted)

    persisted.reload
    expect(persisted.approval_status).to eq('pending')
    expect(persisted.external_template_id).to eq('777')
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
