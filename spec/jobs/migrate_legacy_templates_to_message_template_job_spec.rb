# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MigrateLegacyTemplatesToMessageTemplateJob, type: :job do
  # Channels are built without validation, mirroring the EVO-1232 job spec.
  def whatsapp_channel(provider:)
    channel = Channel::Whatsapp.new(provider: provider, phone_number: "+1555#{SecureRandom.hex(3)}")
    channel.save!(validate: false)
    channel
  end

  # A channel-coupled (channel_id NOT NULL) template — the migration source shape.
  def coupled_template(channel:, name:, content: 'Hello {{name}}', **attrs)
    MessageTemplate.create!(channel: channel, name: name, content: content, language: 'pt_BR', **attrs)
  end

  def globals
    MessageTemplate.where(channel_id: nil)
  end

  let(:baileys) { whatsapp_channel(provider: 'baileys') }

  describe 'dry run (AC1)' do
    it 'writes nothing and reports the count that would migrate per source/skip reason' do
      coupled_template(channel: baileys, name: 'Promo A')
      coupled_template(channel: baileys, name: 'Promo B')

      expect do
        @summary = described_class.new.perform(dry_run: true)
      end.not_to change(globals, :count)

      expect(@summary[:dry_run]).to be(true)
      expect(@summary[:migrated]['whatsapp_legacy_template']).to eq(2)
      expect(@summary[:skipped]).to be_empty
    end

    it 'predicts the SAME count a real run produces for same-named sources (F1 regression)' do
      c2 = whatsapp_channel(provider: 'baileys')
      coupled_template(channel: baileys, name: 'Shared', content: 'A')
      coupled_template(channel: c2, name: 'Shared', content: 'B')

      summary = described_class.new.perform(dry_run: true)

      # One global would be created; the second same-named row is a duplicate —
      # exactly what a real run yields. Dry run must not double-count.
      migrated_total = summary[:migrated].values.sum
      expect(migrated_total).to eq(1)
      expect(summary[:skipped][:duplicate_name]).to eq(1)
      expect(globals.count).to eq(0)
    end
  end

  describe 'normal run (AC2)' do
    it 'creates a channel-less global counterpart and leaves the original untouched' do
      source = coupled_template(channel: baileys, name: 'Welcome', content: 'Hi {{name}}', category: 'UTILITY')

      described_class.new.perform

      copy = MessageTemplate.find_by(external_legacy_id: "message_template:#{source.id}")
      expect(copy).to be_present
      expect(copy.channel_id).to be_nil
      expect(copy.content).to eq('Hi {{name}}')
      expect(copy.category).to eq('UTILITY')
      expect(copy.variables.map { |v| v['name'] }).to include('name')

      source.reload
      expect(source.channel_id).to eq(baileys.id)
      expect(source.external_legacy_id).to be_nil
    end
  end

  describe 'idempotency (AC3)' do
    it 'creates nothing on a second run' do
      coupled_template(channel: baileys, name: 'Once')

      described_class.new.perform
      expect do
        @summary = described_class.new.perform
      end.not_to change(globals, :count)

      expect(@summary[:skipped][:already_migrated]).to eq(1)
      expect(@summary[:migrated]).to be_empty
    end
  end

  describe 'invalid content (AC4)' do
    it 'skips a blank-content row under :invalid_content' do
      blank = MessageTemplate.new(channel: baileys, name: 'Blank', content: '', language: 'pt_BR')
      blank.save!(validate: false)

      summary = described_class.new.perform

      expect(summary[:skipped][:invalid_content]).to eq(1)
      expect(globals.count).to eq(0)
    end
  end

  describe 'WhatsApp Cloud (AC5)' do
    it 'keeps Cloud templates channel-bound and creates no global' do
      cloud = whatsapp_channel(provider: 'whatsapp_cloud')
      source = coupled_template(channel: cloud, name: 'Cloud One', category: 'UTILITY',
                                components: [{ 'type' => 'BODY', 'text' => 'Hi' }])

      summary = described_class.new.perform

      expect(summary[:skipped][:whatsapp_cloud]).to eq(1)
      expect(globals.count).to eq(0)
      expect(source.reload.channel_id).to eq(cloud.id)
    end
  end

  describe 'name collisions (AC6)' do
    it 'suffixes "(legacy)" when a genuine admin global already owns the name' do
      MessageTemplate.create!(channel: nil, name: 'Offer', content: 'admin copy') # admin global, no legacy id
      source = coupled_template(channel: baileys, name: 'Offer', content: 'legacy copy')

      described_class.new.perform

      copy = MessageTemplate.find_by(external_legacy_id: "message_template:#{source.id}")
      expect(copy.name).to eq('Offer (legacy)')
      expect(globals.find_by(name: 'Offer').external_legacy_id).to be_nil # admin row intact
    end

    it 'creates exactly one global when two legacy rows share a name' do
      c2 = whatsapp_channel(provider: 'baileys')
      coupled_template(channel: baileys, name: 'Dup', content: 'A')
      coupled_template(channel: c2, name: 'Dup', content: 'B')

      summary = described_class.new.perform

      expect(globals.where(name: 'Dup').count).to eq(1)
      expect(summary[:skipped][:duplicate_name]).to eq(1)
    end
  end

  describe 'rollback scope (AC7)' do
    it 'deletes only migrated globals, leaving originals and admin globals' do
      admin = MessageTemplate.create!(channel: nil, name: 'Kept', content: 'admin')
      source = coupled_template(channel: baileys, name: 'Migrated')
      described_class.new.perform

      # Mirrors lib/tasks/templates.rake rollback_legacy_migration.
      MessageTemplate.where.not(external_legacy_id: nil).delete_all

      expect(MessageTemplate.exists?(admin.id)).to be(true)
      expect(MessageTemplate.exists?(source.id)).to be(true)
      expect(globals.where.not(external_legacy_id: nil).count).to eq(0)
    end
  end
end
