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

  # EVO-1717 [Follow-up 6.8]: a WABA can host multiple whatsapp_cloud channels, but
  # Meta's template id (metadata['external_id']) is unique per-WABA. The status
  # update must resolve the template across ALL channels of the WABA, not just the
  # `.first` one that find_channel_by_waba_id returns.
  describe 'multi-channel WABA' do
    let(:sibling_channel) do
      ch = Channel::Whatsapp.new(
        provider: 'whatsapp_cloud',
        phone_number: "+1555#{SecureRandom.hex(3)}",
        provider_config: { 'waba_id' => waba_id }
      )
      ch.save!(validate: false)
      ch
    end

    let!(:sibling_template) do
      MessageTemplate.create!(
        name: "wac-#{SecureRandom.hex(4)}", content: 'Hi', channel: sibling_channel,
        metadata: { 'external_id' => '99999' }, settings: { 'status' => 'PENDING' }
      )
    end

    before { Inbox.create!(channel: sibling_channel, name: "Inbox #{SecureRandom.hex(3)}") }

    # Deterministic regression guard: exercises the lookup directly so it does not
    # depend on which channel find_channel_by_waba_id.first happens to return.
    it 'resolves a template living on a sibling channel of the same WABA' do
      found = described_class.new.send(:find_template_for_waba, waba_id, '99999')
      expect(found).to eq(sibling_template)
    end

    it 'does not match an external id from a different WABA' do
      found = described_class.new.send(:find_template_for_waba, "other-#{SecureRandom.hex(4)}", '99999')
      expect(found).to be_nil
    end

    it 'returns nil for a blank WABA id' do
      expect(described_class.new.send(:find_template_for_waba, '', '99999')).to be_nil
    end

    it 'updates the sibling-channel template status end-to-end' do
      described_class.new.perform(payload(event: 'APPROVED', message_template_id: '99999'))

      expect(sibling_template.reload.settings['status']).to eq('APPROVED')
      expect(sibling_template.approval_status).to eq('approved')
    end

    # The webhook write goes through update_columns, so it must land even on a
    # record that would fail model validation (e.g. blank content). (EVO-1717 AC4)
    it 'writes the status via update_columns even when the record is model-invalid' do
      invalid_template = MessageTemplate.new(
        name: "wac-#{SecureRandom.hex(4)}", content: '', channel: sibling_channel,
        metadata: { 'external_id' => '77777' }, settings: { 'status' => 'PENDING' }
      )
      invalid_template.save!(validate: false)
      expect(invalid_template).not_to be_valid

      described_class.new.perform(payload(event: 'APPROVED', message_template_id: '77777'))

      expect(invalid_template.reload.settings['status']).to eq('APPROVED')
    end
  end

  # EVO-1967: classificacao de evento de mensagem + reconciliacao ativa do canal.
  describe '#message_event?' do
    it 'is true for evolution messages.upsert' do
      expect(described_class.new.send(:message_event?, { event: 'messages.upsert' })).to be(true)
    end

    it 'is true for a nested WhatsApp Cloud message payload (entry/changes/value/messages)' do
      cloud = { entry: [{ changes: [{ value: { messages: [{ id: 'x' }] } }] }] }.with_indifferent_access
      expect(described_class.new.send(:message_event?, cloud)).to be(true)
    end

    it 'is false for connection.update / non-message events' do
      expect(described_class.new.send(:message_event?, { event: 'connection.update' })).to be(false)
    end
  end

  describe '#reconcile_channel_state! (EVO-1967 Fix B: active reconciliation)' do
    let(:job) { described_class.new }
    let(:evo_channel) do
      instance_double(
        Channel::Whatsapp, id: 1, provider: 'evolution',
        provider_config: { 'api_url' => 'http://evolution-api:8080', 'instance_name' => 'vendedor-2', 'instance_token' => 'k' }
      )
    end

    before do
      allow(evo_channel).to receive(:is_a?).with(Channel::Whatsapp).and_return(true)
      allow(job).to receive(:reconcile_on_cooldown?).and_return(false)
      allow(job).to receive(:set_reconcile_cooldown!)
    end

    it 'marks the channel connected and returns true when Evolution reports open' do
      allow(job).to receive(:evolution_connection_state).and_return('open')
      expect(evo_channel).to receive(:mark_connected!)
      expect(job.send(:reconcile_channel_state!, evo_channel, { instance: 'vendedor-2' })).to be(true)
    end

    it 'does NOT mark connected (and arms cooldown) when Evolution reports a closed state' do
      allow(job).to receive(:evolution_connection_state).and_return('close')
      expect(evo_channel).not_to receive(:mark_connected!)
      expect(job).to receive(:set_reconcile_cooldown!).with(evo_channel)
      expect(job.send(:reconcile_channel_state!, evo_channel, {})).to be(false)
    end

    it 'short-circuits (no HTTP) while on cooldown' do
      allow(job).to receive(:reconcile_on_cooldown?).and_return(true)
      expect(job).not_to receive(:evolution_connection_state)
      expect(job.send(:reconcile_channel_state!, evo_channel, {})).to be(false)
    end

    it 'returns false (skips) for non-evolution providers' do
      cloud = instance_double(Channel::Whatsapp, provider: 'whatsapp_cloud')
      allow(cloud).to receive(:is_a?).with(Channel::Whatsapp).and_return(true)
      expect(job.send(:reconcile_channel_state!, cloud, {})).to be(false)
    end

    it 'returns false when provider_config is incomplete' do
      bare = instance_double(Channel::Whatsapp, provider: 'evolution', provider_config: {})
      allow(bare).to receive(:is_a?).with(Channel::Whatsapp).and_return(true)
      expect(job.send(:reconcile_channel_state!, bare, {})).to be(false)
    end

    it 'is resilient: returns false if reconciliation raises' do
      allow(job).to receive(:evolution_connection_state).and_raise(StandardError)
      expect(job.send(:reconcile_channel_state!, evo_channel, {})).to be(false)
    end
  end
end
