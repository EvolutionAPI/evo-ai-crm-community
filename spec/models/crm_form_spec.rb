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
      expect(form.errors[:fields].join).to include('mapped to name')
    end

    it 'rejects invalid field types and maps_to' do
      form = build_form(fields: valid_fields + [{ 'key' => 'x', 'type' => 'bogus', 'maps_to' => 'nope' }])
      expect(form).not_to be_valid
      expect(form.errors[:fields].join).to include('invalid type', 'invalid maps_to')
    end

    it 'rejects routing rules without a pipeline_id' do
      form = build_form(routing_rules: [{ 'field' => 'plan', 'op' => 'equals', 'value' => 'pro' }])
      expect(form).not_to be_valid
      expect(form.errors[:routing_rules].join).to include('requires a pipeline_id')
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
end
