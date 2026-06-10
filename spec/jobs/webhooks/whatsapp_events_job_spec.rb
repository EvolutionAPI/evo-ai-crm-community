# frozen_string_literal: true

require 'rails_helper'

# EVO-1232 [6.3]: Meta pushes template approval status to the WhatsApp webhook;
# WhatsappEventsJob ingests `message_template_status_update` and updates the
# matching template's settings['status'] (keyed by metadata['external_id']).
RSpec.describe Webhooks::WhatsappEventsJob, type: :job do
  let(:waba_id) { "waba-#{SecureRandom.hex(4)}" }

  let(:channel) do
    ch = Channel::Whatsapp.new(
      provider: 'whatsapp_cloud',
      phone_number: "+1555#{SecureRandom.hex(3)}",
      provider_config: { 'waba_id' => waba_id }
    )
    ch.save!(validate: false)
    ch
  end

  let!(:template) do
    MessageTemplate.create!(
      name: "wac-#{SecureRandom.hex(4)}", content: 'Hi', channel: channel,
      metadata: { 'external_id' => '12345' }, settings: { 'status' => 'PENDING' }
    )
  end

  # find_channel_by_waba_id joins(:inbox), so the channel needs an inbox.
  before { Inbox.create!(channel: channel, name: "Inbox #{SecureRandom.hex(3)}") }

  def payload(event:, message_template_id: '12345', reason: nil)
    {
      object: 'whatsapp_business_account',
      entry: [
        {
          id: waba_id,
          changes: [
            {
              field: 'message_template_status_update',
              value: {
                event: event,
                message_template_id: message_template_id,
                message_template_name: template.name,
                reason: reason
              }
            }
          ]
        }
      ]
    }.with_indifferent_access
  end

  it 'detects the event as a sync event (so it is not misrouted to messages)' do
    expect(described_class.new.send(:sync_event?, payload(event: 'APPROVED'))).to be(true)
  end

  it 'resolves the WhatsApp Cloud channel by WABA id (adversarial review F3)' do
    resolved = described_class.new.send(:find_channel, payload(event: 'APPROVED'))
    expect(resolved).to eq(channel)
  end

  it 'updates the template status to APPROVED (approval_status approved)' do
    described_class.new.perform(payload(event: 'APPROVED'))

    template.reload
    expect(template.settings['status']).to eq('APPROVED')
    expect(template.approval_status).to eq('approved')
  end

  it 'records the rejection reason on REJECTED' do
    described_class.new.perform(payload(event: 'REJECTED', reason: 'INVALID_FORMAT'))

    template.reload
    expect(template.settings['status']).to eq('REJECTED')
    expect(template.approval_status).to eq('rejected')
    expect(template.metadata['rejected_reason']).to eq('INVALID_FORMAT')
  end

  it 'is a no-op (no error) when no template matches the external id' do
    expect do
      described_class.new.perform(payload(event: 'APPROVED', message_template_id: 'does-not-exist'))
    end.not_to raise_error

    expect(template.reload.settings['status']).to eq('PENDING')
  end
end
