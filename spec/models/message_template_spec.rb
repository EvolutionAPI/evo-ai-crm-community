# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MessageTemplate, type: :model do
  describe '#serialized' do
    let(:template) do
      described_class.new(
        name: 'ini_conversa',
        content: 'Olá, tudo bem?',
        language: 'pt_BR',
        category: 'UTILITY',
        template_type: 'text',
        components: [{ 'text' => 'Olá, tudo bem?', 'type' => 'BODY' }],
        variables: [],
        active: true
      )
    end

    it 'mirrors settings.status as a top-level status key when present' do
      template.settings = { 'status' => 'APPROVED' }
      expect(template.serialized['status']).to eq('APPROVED')
    end

    it 'returns nil for top-level status when settings is empty' do
      template.settings = {}
      expect(template.serialized).to have_key('status')
      expect(template.serialized['status']).to be_nil
    end

    it 'returns nil for top-level status when settings lacks the status key' do
      template.settings = { 'quality_score' => 'HIGH' }
      expect(template.serialized['status']).to be_nil
    end

    it 'does not raise when settings itself is nil' do
      template.settings = nil
      expect { template.serialized }.not_to raise_error
      expect(template.serialized['status']).to be_nil
    end

    it 'does not raise when settings is not a Hash (defensive guard)' do
      template.settings = 'malformed'
      expect { template.serialized }.not_to raise_error
      expect(template.serialized['status']).to be_nil
    end

    it 'still exposes the full settings hash alongside the mirrored status' do
      template.settings = { 'status' => 'PENDING', 'source' => 'meta_api' }
      serialized = template.serialized
      expect(serialized['status']).to eq('PENDING')
      expect(serialized['settings']).to eq({ 'status' => 'PENDING', 'source' => 'meta_api' })
    end
  end

  # EVO-1231 [6.2]: templates can exist as global (channel-less) records;
  # WhatsApp Cloud templates still require a channel.
  describe 'channel decoupling' do
    def whatsapp_channel(provider:)
      channel = Channel::Whatsapp.new(provider: provider, phone_number: "+1555#{SecureRandom.hex(3)}")
      channel.save!(validate: false)
      channel
    end

    it 'persists a global (channel-less) template' do
      template = described_class.create!(name: "global-#{SecureRandom.hex(4)}", content: 'Hello')

      expect(template.channel_id).to be_nil
      expect(template.channel_type).to be_nil
    end

    it 'is invalid as a channel-less WhatsApp Cloud template' do
      template = described_class.new(
        name: "wac-#{SecureRandom.hex(4)}", content: 'Hello', intended_provider: 'whatsapp_cloud'
      )

      expect(template).not_to be_valid
      expect(template.errors[:channel]).to include('is required for WhatsApp Cloud templates')
    end

    it 'is valid as a WhatsApp Cloud template when a channel is present' do
      template = described_class.new(
        name: "wac-#{SecureRandom.hex(4)}", content: 'Hello',
        channel: whatsapp_channel(provider: 'whatsapp_cloud'), intended_provider: 'whatsapp_cloud'
      )

      expect(template).to be_valid
    end

    it 'enforces a unique name among global templates' do
      name = "dup-#{SecureRandom.hex(4)}"
      described_class.create!(name: name, content: 'first')

      duplicate = described_class.new(name: name, content: 'second')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to be_present
    end

    it 'allows a channel-bound template to reuse a global template name' do
      name = "shared-#{SecureRandom.hex(4)}"
      described_class.create!(name: name, content: 'global')

      bound = described_class.new(
        name: name, content: 'bound', channel: whatsapp_channel(provider: 'evolution')
      )

      expect(bound).to be_valid
    end
  end

  # EVO-1232 [6.3]: a WhatsApp Cloud template must be bound to a channel that is
  # actually a WhatsApp Cloud channel (type + provider), not merely present.
  describe 'WhatsApp Cloud channel type enforcement' do
    def whatsapp_channel(provider:)
      channel = Channel::Whatsapp.new(provider: provider, phone_number: "+1555#{SecureRandom.hex(3)}")
      channel.save!(validate: false)
      channel
    end

    it 'is invalid when the channel is a WhatsApp channel of another provider' do
      template = described_class.new(
        name: "wac-#{SecureRandom.hex(4)}", content: 'Hi',
        channel: whatsapp_channel(provider: 'baileys'), intended_provider: 'whatsapp_cloud'
      )

      expect(template).not_to be_valid
      expect(template.errors[:channel]).to include('must reference a WhatsApp Cloud channel')
    end

    it 'is invalid when the channel is not a WhatsApp channel at all' do
      template = described_class.new(
        name: "wac-#{SecureRandom.hex(4)}", content: 'Hi',
        channel: Channel::Api.create!(hmac_mandatory: false), intended_provider: 'whatsapp_cloud'
      )

      expect(template).not_to be_valid
      expect(template.errors[:channel]).to include('must reference a WhatsApp Cloud channel')
    end

    it 'treats a template bound to a WhatsApp Cloud channel as WhatsApp Cloud even without intended_provider' do
      template = described_class.new(
        name: "wac-#{SecureRandom.hex(4)}", content: 'Hi',
        channel: whatsapp_channel(provider: 'whatsapp_cloud')
      )

      expect(template).to be_valid
    end
  end

  # EVO-1232 [6.3]: Meta sync data is read through normalized accessors over the
  # canonical JSONB (settings['status'] + metadata['external_id']).
  describe '#approval_status' do
    subject(:template) { described_class.new(name: 'n', content: 'c') }

    it 'is draft when never synced (blank status)' do
      template.settings = {}
      expect(template.approval_status).to eq('draft')
    end

    it 'normalizes Meta APPROVED to approved' do
      template.settings = { 'status' => 'APPROVED' }
      expect(template.approval_status).to eq('approved')
    end

    it 'normalizes PENDING_QUALITY_CHECK to pending' do
      template.settings = { 'status' => 'PENDING_QUALITY_CHECK' }
      expect(template.approval_status).to eq('pending')
    end

    it 'normalizes PAUSED and FLAGGED' do
      template.settings = { 'status' => 'PAUSED' }
      expect(template.approval_status).to eq('paused')
      template.settings = { 'status' => 'FLAGGED' }
      expect(template.approval_status).to eq('flagged')
    end

    it 'falls back to a downcased value for unknown statuses' do
      template.settings = { 'status' => 'SOMETHING_NEW' }
      expect(template.approval_status).to eq('something_new')
    end

    it 'is draft when settings is not a Hash (defensive)' do
      template.settings = 'malformed'
      expect(template.approval_status).to eq('draft')
    end
  end

  describe '#external_template_id' do
    subject(:template) { described_class.new(name: 'n', content: 'c') }

    it 'reads metadata external_id' do
      template.metadata = { 'external_id' => '12345' }
      expect(template.external_template_id).to eq('12345')
    end

    it 'is nil when metadata lacks external_id' do
      template.metadata = { 'namespace' => 'ns' }
      expect(template.external_template_id).to be_nil
    end
  end

  describe '#serialized (EVO-1232 fields)' do
    it 'exposes approval_status and external_template_id' do
      template = described_class.new(
        name: 'n', content: 'c',
        settings: { 'status' => 'APPROVED' }, metadata: { 'external_id' => '999' }
      )

      serialized = template.serialized
      expect(serialized['approval_status']).to eq('approved')
      expect(serialized['external_template_id']).to eq('999')
      # Raw Meta status is still exposed for backward compatibility.
      expect(serialized['status']).to eq('APPROVED')
    end
  end
end
