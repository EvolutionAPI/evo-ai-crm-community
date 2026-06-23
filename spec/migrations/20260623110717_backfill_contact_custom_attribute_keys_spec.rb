require 'rails_helper'
require_relative '../../db/migrate/20260623110717_backfill_contact_custom_attribute_keys'

RSpec.describe BackfillContactCustomAttributeKeys, type: :migration do
  let(:migration) { described_class.new.tap { |m| m.verbose = false } }

  # Use the migration's validation-free inner models so seeding does not depend
  # on app-model validations / associations.
  let(:definition_model) { described_class::CustomAttributeDefinition }
  let(:contact_model) { described_class::Contact }

  def define_attr(display_name:, key:)
    definition_model.create!(
      attribute_display_name: display_name,
      attribute_key: key,
      attribute_display_type: 0,
      attribute_model: described_class::CONTACT_ATTRIBUTE_MODEL,
    )
  end

  def attrs_for(contact)
    contact_model.find(contact.id).custom_attributes
  end

  describe '#up' do
    it 'remaps a display-name key to its attribute_key slug' do
      define_attr(display_name: 'Plan Interest', key: 'plan_interest')
      contact = contact_model.create!(custom_attributes: { 'Plan Interest' => 'gold' })

      migration.up

      expect(attrs_for(contact)).to eq('plan_interest' => 'gold')
    end

    it 'preserves other custom attributes (no wipe)' do
      define_attr(display_name: 'Plan Interest', key: 'plan_interest')
      contact = contact_model.create!(
        custom_attributes: { 'Plan Interest' => 'gold', 'other_key' => 'keep' },
      )

      migration.up

      expect(attrs_for(contact)).to eq(
        'plan_interest' => 'gold',
        'other_key' => 'keep',
      )
    end

    it 'is collision-safe: never clobbers an existing slug value' do
      define_attr(display_name: 'Plan Interest', key: 'plan_interest')
      contact = contact_model.create!(
        custom_attributes: { 'Plan Interest' => 'old', 'plan_interest' => 'new' },
      )

      migration.up

      result = attrs_for(contact)
      expect(result['plan_interest']).to eq('new')
      expect(result['Plan Interest']).to eq('old') # stray key left untouched
    end

    it 'is ambiguity-safe: skips display names that map to >1 key' do
      define_attr(display_name: 'Duplicated', key: 'dup_a')
      define_attr(display_name: 'Duplicated', key: 'dup_b')
      contact = contact_model.create!(custom_attributes: { 'Duplicated' => 'x' })

      migration.up

      expect(attrs_for(contact)).to eq('Duplicated' => 'x') # untouched
    end

    it 'is idempotent: a second run is a no-op' do
      define_attr(display_name: 'Plan Interest', key: 'plan_interest')
      contact = contact_model.create!(custom_attributes: { 'Plan Interest' => 'gold' })

      migration.up
      first = attrs_for(contact)
      migration.up

      expect(attrs_for(contact)).to eq(first)
      expect(attrs_for(contact)).to eq('plan_interest' => 'gold')
    end
  end

  describe '#down' do
    it 'is irreversible' do
      expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    end
  end
end
