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

    it 'predicts the SAME count a real run produces for same-named sources (EVO-1718 preserve-both)' do
      c2 = whatsapp_channel(provider: 'baileys')
      coupled_template(channel: baileys, name: 'Shared', content: 'A')
      coupled_template(channel: c2, name: 'Shared', content: 'B')

      summary = described_class.new.perform(dry_run: true)

      # Both rows are preserved (the 2nd gets a suffixed name), so a real run
      # would create TWO globals — dry run must predict the same and skip nothing.
      migrated_total = summary[:migrated].values.sum
      expect(migrated_total).to eq(2)
      expect(summary[:skipped]).to be_empty
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

    it 'preserves both legacy rows when two share a name (2nd suffixed)' do
      c2 = whatsapp_channel(provider: 'baileys')
      coupled_template(channel: baileys, name: 'Dup', content: 'A')
      coupled_template(channel: c2, name: 'Dup', content: 'B')

      summary = described_class.new.perform

      # find_in_batches orders by id, so the earlier row keeps the bare name and
      # the later one is suffixed — both survive, nothing is skipped.
      migrated_names = globals.where.not(external_legacy_id: nil).pluck(:name)
      expect(migrated_names).to contain_exactly('Dup', 'Dup (legacy)')
      expect(summary[:migrated].values.sum).to eq(2)
      expect(summary[:skipped]).to be_empty
    end
  end

  describe 'rollback scope (AC7)' do
    it 'deletes only this migration\'s globals, leaving originals, admin globals, and foreign-provenance rows' do
      admin = MessageTemplate.create!(channel: nil, name: 'Kept', content: 'admin')
      source = coupled_template(channel: baileys, name: 'Migrated')
      # A global tagged by a hypothetical OTHER integration. The old unscoped
      # rollback (where.not(external_legacy_id: nil)) would have wrongly deleted
      # this; the prefix-scoped delete must spare it. Without this row the test
      # is vacuous — it would pass against the old scope too.
      foreign = MessageTemplate.create!(channel: nil, name: 'Foreign', content: 'x',
                                        external_legacy_id: 'other_integration:1')
      described_class.new.perform

      # Mirrors lib/tasks/templates.rake rollback_legacy_migration (prefix-scoped).
      MessageTemplate.where('external_legacy_id LIKE ?', "#{described_class::LEGACY_KEY_PREFIX}:%").delete_all

      expect(MessageTemplate.exists?(admin.id)).to be(true)
      expect(MessageTemplate.exists?(source.id)).to be(true)
      expect(MessageTemplate.exists?(foreign.id)).to be(true)
      expect(globals.where('external_legacy_id LIKE ?', "#{described_class::LEGACY_KEY_PREFIX}:%").count).to eq(0)
    end
  end

  # EVO-1718 follow-up: the AC labels above (AC1–AC7) are EVO-1234's. The blocks
  # below cover the EVO-1718 review findings directly; they are named by finding
  # rather than reusing the AСn labels to avoid collision.

  # F2: defensive enum symmetry. NOTE — in Rails 7.1 the media_type reader already
  # nils any out-of-enum stored value, so this guard fixes no observed bug; we
  # unit-test the guard directly (a DB round-trip would be a tautology).
  describe 'media_type normalization (EVO-1718 F2)' do
    it 'maps unknown/blank/nil media_type to nil and passes valid keys through' do
      job = described_class.new
      expect(job.send(:normalized_media_type, 'sticker')).to be_nil
      expect(job.send(:normalized_media_type, '')).to be_nil
      expect(job.send(:normalized_media_type, nil)).to be_nil
      expect(job.send(:normalized_media_type, 'image')).to eq('image')
    end
  end

  # F11: channel_type drives the source label. We exercise the private mapper with
  # a stub rather than building a real Telegram-coupled template — wiring a
  # mismatched polymorphic channel_type/channel_id would pass for the wrong reason.
  describe 'source label by channel_type (EVO-1718 F11)' do
    it 'maps known channel types to their label and falls back to the default' do
      job = described_class.new
      expect(job.send(:source_label, instance_double(MessageTemplate, channel_type: 'Channel::Telegram')))
        .to eq('telegram_legacy_template')
      expect(job.send(:source_label, instance_double(MessageTemplate, channel_type: 'Channel::Instagram')))
        .to eq('instagram_legacy_template')
      expect(job.send(:source_label, instance_double(MessageTemplate, channel_type: 'Channel::Unknown')))
        .to eq('other_legacy_template')
    end
  end

  # F5: the copy's before_save re-derives variables from {{tokens}} in content.
  # The Dec-2025 rows were written by raw SQL, so they can carry synthetic
  # component vars (var_1...) absent from content. update_columns reproduces that
  # callback-bypassing shape (the model would otherwise prune them on save).
  describe 'synthetic variable pruning on the copy (EVO-1718 F5)' do
    it 'drops component-derived vars absent from content, keeping real tokens' do
      source = coupled_template(channel: baileys, name: 'Vars', content: 'Hi {{name}}')
      # rubocop:disable Rails/SkipsModelValidations -- intentional: mimic the raw
      # Dec-2025 SQL write that bypasses the model's variable-pruning callback.
      source.update_columns(variables: [
                              { 'name' => 'name', 'type' => 'text', 'required' => false },
                              { 'name' => 'var_1', 'type' => 'text', 'required' => false }
                            ])
      # rubocop:enable Rails/SkipsModelValidations

      described_class.new.perform

      copy = MessageTemplate.find_by(external_legacy_id: "message_template:#{source.id}")
      var_names = copy.variables.map { |v| v['name'] }
      expect(var_names).to include('name')
      expect(var_names).not_to include('var_1')
    end
  end

  # F3/F10: an unexpected create! failure is rescued, logged with the record's
  # validation messages (not an empty string), and bucketed under :error.
  describe 'unexpected create failure diagnostics (EVO-1718)' do
    it 'logs the record full_messages and buckets the row under :error' do
      coupled_template(channel: baileys, name: 'Boom', content: 'hi')

      invalid = MessageTemplate.new
      invalid.errors.add(:content, "can't be blank")
      allow(MessageTemplate).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(invalid))
      allow(Rails.logger).to receive(:error).and_call_original

      summary = described_class.new.perform

      expect(Rails.logger).to have_received(:error).with(/Content can't be blank/)
      expect(summary[:skipped][described_class::REASON_ERROR]).to eq(1)
      expect(globals.count).to eq(0)
    end
  end
end
