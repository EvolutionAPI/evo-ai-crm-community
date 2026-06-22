# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmForm, type: :model do
  let(:user) { User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: 'Owner') }
  let(:pipeline) { Pipeline.create!(name: "Sales #{SecureRandom.hex(4)}", pipeline_type: 'sales', created_by: user) }
  let!(:stage) { pipeline.pipeline_stages.create!(name: 'New', position: 1) }

  let(:valid_fields) do
    [
      { 'key' => 'full_name', 'label' => 'Name', 'type' => 'text', 'required' => true, 'maps_to' => 'name' },
      { 'key' => 'email', 'label' => 'Email', 'type' => 'email', 'required' => true, 'maps_to' => 'email' }
    ]
  end

  def build_form(attrs = {})
    CrmForm.new({
      name: 'Contact Us',
      default_pipeline: pipeline,
      default_stage: stage,
      fields: valid_fields
    }.merge(attrs))
  end

  describe 'slug generation' do
    it 'derives a slug from the name on create' do
      form = build_form(name: 'My Lead Form')
      form.save!
      expect(form.slug).to eq('my-lead-form')
    end

    it 'disambiguates colliding slugs' do
      build_form(name: 'Dup').save!
      second = build_form(name: 'Dup')
      second.save!
      expect(second.slug).to eq('dup-2')
    end

    it 'keeps an explicitly provided slug' do
      form = build_form(slug: 'custom-slug')
      form.save!
      expect(form.slug).to eq('custom-slug')
    end
  end

  describe 'validations' do
    it 'requires a field mapped to email and name' do
      form = build_form(fields: [{ 'key' => 'email', 'maps_to' => 'email' }])
      expect(form).not_to be_valid
      expect(form.errors[:fields].join).to include('mapped to contact name')
    end

    it 'rejects invalid field types and mapping targets' do
      form = build_form(fields: valid_fields + [{ 'key' => 'x', 'type' => 'bogus', 'maps_to' => 'nope' }])
      expect(form).not_to be_valid
      expect(form.errors[:fields].join).to include('invalid type', 'invalid mapping target')
    end

    it 'accepts typed mapping targets (kind + key)' do
      form = build_form(fields: valid_fields + [
        { 'key' => 'city', 'maps_to' => 'contact_attribute', 'maps_to_key' => 'city' },
        { 'key' => 'budget', 'maps_to' => 'deal_value' }
      ])
      expect(form).to be_valid
    end

    it 'rejects routing rules without a pipeline_id' do
      form = build_form(routing_rules: [{ 'field' => 'plan', 'op' => 'equals', 'value' => 'pro' }])
      expect(form).not_to be_valid
      expect(form.errors[:routing_rules].join).to include('requires a pipeline_id')
    end

    it 'rejects a routing rule pointing at a pipeline that does not exist' do
      form = build_form(routing_rules: [
        { 'field' => 'plan', 'op' => 'equals', 'value' => 'pro', 'pipeline_id' => SecureRandom.uuid }
      ])
      expect(form).not_to be_valid
      expect(form.errors[:routing_rules].join).to include('pipeline that does not exist')
    end

    it 'rejects a routing rule whose stage does not belong to its pipeline' do
      foreign = Pipeline.create!(name: "Other #{SecureRandom.hex(4)}", pipeline_type: 'sales', created_by: user)
      foreign_stage = foreign.pipeline_stages.create!(name: 'Elsewhere', position: 1)
      form = build_form(routing_rules: [
        { 'field' => 'plan', 'op' => 'equals', 'value' => 'pro', 'pipeline_id' => pipeline.id, 'stage_id' => foreign_stage.id }
      ])
      expect(form).not_to be_valid
      expect(form.errors[:routing_rules].join).to include('stage that does not belong to the pipeline')
    end

    it 'accepts a routing rule with a consistent pipeline/stage' do
      form = build_form(routing_rules: [
        { 'field' => 'plan', 'op' => 'equals', 'value' => 'pro', 'pipeline_id' => pipeline.id, 'stage_id' => stage.id }
      ])
      expect(form).to be_valid
    end

    it 'rejects a default stage that does not belong to the default pipeline' do
      foreign = Pipeline.create!(name: "Other #{SecureRandom.hex(4)}", pipeline_type: 'sales', created_by: user)
      foreign_stage = foreign.pipeline_stages.create!(name: 'Elsewhere', position: 1)
      form = build_form(default_stage: foreign_stage)
      expect(form).not_to be_valid
      expect(form.errors[:default_stage].join).to include('must belong to the default pipeline')
    end
  end

  describe '.field_target' do
    it 'resolves the legacy string form' do
      expect(CrmForm.field_target('maps_to' => 'email')).to eq([:contact, 'email'])
    end

    it 'resolves typed contact_attribute / deal_value / deal_attribute' do
      expect(CrmForm.field_target('maps_to' => 'contact_attribute', 'maps_to_key' => 'city')).to eq([:contact_attribute, 'city'])
      expect(CrmForm.field_target('maps_to' => 'deal_value')).to eq([:deal_value, 'value'])
      expect(CrmForm.field_target('maps_to' => 'deal_attribute', 'maps_to_key' => 'source')).to eq([:deal_attribute, 'source'])
    end

    it 'returns nil for blank or invalid targets' do
      expect(CrmForm.field_target('maps_to' => '')).to be_nil
      expect(CrmForm.field_target('maps_to' => 'nope')).to be_nil
      expect(CrmForm.field_target('maps_to' => 'contact_attribute')).to be_nil
    end
  end

  describe '#resolve_destination' do
    let(:other_pipeline) { Pipeline.create!(name: "Support #{SecureRandom.hex(4)}", pipeline_type: 'support', created_by: user) }
    let!(:other_stage) { other_pipeline.pipeline_stages.create!(name: 'Triage', position: 1) }

    it 'routes by a matching rule' do
      form = build_form(routing_rules: [
        { 'field' => 'plan', 'op' => 'equals', 'value' => 'pro', 'pipeline_id' => other_pipeline.id, 'stage_id' => other_stage.id }
      ])
      form.save!
      expect(form.resolve_destination('plan' => 'pro')).to eq([other_pipeline.id, other_stage.id])
    end

    it 'falls back to the default pipeline/stage when no rule matches' do
      form = build_form(routing_rules: [
        { 'field' => 'plan', 'op' => 'equals', 'value' => 'pro', 'pipeline_id' => other_pipeline.id, 'stage_id' => other_stage.id }
      ])
      form.save!
      expect(form.resolve_destination('plan' => 'free')).to eq([pipeline.id, stage.id])
    end
  end

  describe 'captured leads (B14.07)' do
    let(:form) { build_form.tap(&:save!) }

    def lead_item(slug)
      contact = Contact.create!(name: 'Lead', email: "lead-#{SecureRandom.hex(4)}@example.com")
      pipeline.pipeline_items.create!(
        contact: contact, pipeline_stage: stage, entered_at: Time.current,
        custom_fields: { 'lead_metadata' => { 'form_slug' => slug } }
      )
    end

    it 'finds only pipeline_items stamped with its form_slug' do
      mine = lead_item(form.slug)
      lead_item('another-form')
      pipeline.pipeline_items.create!(
        contact: Contact.create!(name: 'X', email: "x-#{SecureRandom.hex(4)}@example.com"),
        pipeline_stage: stage, entered_at: Time.current, custom_fields: {}
      )

      expect(form.captured_leads).to contain_exactly(mine)
      expect(CrmForm.lead_counts_by_slug([form.slug])[form.slug]).to eq(1)
    end
  end
end
