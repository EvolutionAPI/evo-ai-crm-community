# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public CRM Forms API', type: :request do
  let(:user) { User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: 'Owner') }
  let(:pipeline) { Pipeline.create!(name: "Sales #{SecureRandom.hex(4)}", pipeline_type: 'sales', created_by: user) }
  let!(:stage) { pipeline.pipeline_stages.create!(name: 'New', position: 1) }

  let(:fields) do
    [
      { 'key' => 'full_name', 'label' => 'Name', 'type' => 'text', 'required' => true, 'maps_to' => 'name' },
      { 'key' => 'email', 'label' => 'Email', 'type' => 'email', 'required' => true, 'maps_to' => 'email' },
      { 'key' => 'plan', 'label' => 'Plan', 'type' => 'select', 'required' => false }
    ]
  end

  let(:form) do
    CrmForm.create!(
      name: 'Contact Us',
      title: 'Talk to us',
      default_pipeline: pipeline,
      default_stage: stage,
      published: true,
      fields: fields
    )
  end

  describe 'GET /public/api/v1/forms/:slug' do
    it 'returns the public form config for a published form' do
      get "/public/api/v1/forms/#{form.slug}"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['data']['title']).to eq('Talk to us')
      expect(body['data']['fields'].map { |f| f['key'] }).to contain_exactly('full_name', 'email', 'plan')
      # Internals must not leak.
      expect(body['data']).not_to have_key('routing_rules')
      expect(body['data']).not_to have_key('default_pipeline_id')
    end

    it '404s for a draft form without leaking it' do
      form.update!(published: false)
      get "/public/api/v1/forms/#{form.slug}"
      expect(response).to have_http_status(:not_found)
    end

    it '404s for an unknown slug' do
      get '/public/api/v1/forms/does-not-exist'
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /public/api/v1/forms/:slug/submissions' do
    let(:path) { "/public/api/v1/forms/#{form.slug}/submissions" }

    it 'creates a contact and a pipeline_item in the form destination' do
      expect do
        post path, params: { submission: { full_name: 'Ada Lovelace', email: "ada-#{SecureRandom.hex(4)}@example.com" } }, as: :json
      end.to change(Contact, :count).by(1).and change(PipelineItem, :count).by(1)

      expect(response).to have_http_status(:created)
      item = PipelineItem.last
      expect(item.pipeline_id).to eq(pipeline.id)
      expect(item.pipeline_stage_id).to eq(stage.id)
    end

    it 'routes to a different pipeline when a rule matches' do
      other_pipeline = Pipeline.create!(name: "Support #{SecureRandom.hex(4)}", pipeline_type: 'support', created_by: user)
      other_stage = other_pipeline.pipeline_stages.create!(name: 'Triage', position: 1)
      form.update!(routing_rules: [
        { 'field' => 'plan', 'op' => 'equals', 'value' => 'pro', 'pipeline_id' => other_pipeline.id, 'stage_id' => other_stage.id }
      ])

      post path, params: { submission: { full_name: 'Pro Lead', email: "pro-#{SecureRandom.hex(4)}@example.com", plan: 'pro' } }, as: :json

      expect(response).to have_http_status(:created)
      expect(PipelineItem.last.pipeline_id).to eq(other_pipeline.id)
    end

    it 'silently discards a submission that trips the honeypot' do
      expect do
        post path, params: { submission: { full_name: 'Bot', email: "bot-#{SecureRandom.hex(4)}@example.com", _hp_url: 'http://spam' } }, as: :json
      end.to change(Contact, :count).by(0).and change(PipelineItem, :count).by(0)

      expect(response).to have_http_status(:created)
    end

    it 'returns 422 when a required field is missing' do
      expect do
        post path, params: { submission: { full_name: 'No Email' } }, as: :json
      end.to change(Contact, :count).by(0)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['success']).to be(false)
    end
  end
end
