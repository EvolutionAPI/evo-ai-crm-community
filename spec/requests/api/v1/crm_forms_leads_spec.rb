# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# EVO-2207 (AC4) — GET /api/v1/crm_forms/:id/leads must return a form's captured
# leads derived from the CONTACT, so a lead survives deletion of its pipeline item
# (the deal). This request spec drives the real route + gate + serializer end-to-end
# (the model spec can't reach serialize_lead): we WebMock evo-auth's /validate and
# /check_permission so `crm_forms.read` gates the endpoint. Three AC cases plus the
# gate: with a live card, after the card is deleted for real, legacy item-only, and
# forbidden without the permission.
RSpec.describe 'Api::V1::CrmForms leads (EVO-2207)', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  let!(:user) { User.create!(name: 'Forms User', email: "forms-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: "Sales #{SecureRandom.hex(4)}", pipeline_type: 'sales', created_by: user) }
  let!(:stage) { pipeline.pipeline_stages.create!(name: 'New', position: 1) }
  let(:form) do
    CrmForm.create!(
      name: "Contact #{SecureRandom.hex(4)}", default_pipeline: pipeline, default_stage: stage,
      fields: [
        { 'key' => 'full_name', 'label' => 'Name', 'type' => 'text', 'required' => true, 'maps_to' => 'name' },
        { 'key' => 'email', 'label' => 'Email', 'type' => 'email', 'required' => true, 'maps_to' => 'email' }
      ]
    )
  end

  around do |example|
    original = ENV.fetch('EVO_AUTH_SERVICE_URL', nil)
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    Rails.cache.clear
    Current.reset
    example.run
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = original
  end

  def json_response
    response.parsed_body
  end

  # Stub /validate (carries the role key) and /check_permission (true only for the
  # granted permission keys), mirroring the bearer-auth path the middleware walks.
  def stub_auth(role_key:, granted: [])
    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: { success: true,
                data: { user: { id: user.id, email: user.email, role: { id: 1, key: role_key, name: role_key } } } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    stub_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
      .to_return do |request|
        key = JSON.parse(request.body)['permission_key']
        { status: 200,
          body: { success: true, data: { has_permission: granted.include?(key) } }.to_json,
          headers: { 'Content-Type' => 'application/json' } }
      end
  end

  def stamped_contact(name)
    Contact.create!(name: name, email: "#{name.downcase}-#{SecureRandom.hex(4)}@example.com",
                    custom_attributes: { Public::Leads::CreationService::CAPTURE_FORMS_ATTRIBUTE => [form.slug] })
  end

  def card_for(contact)
    pipeline.pipeline_items.create!(
      contact: contact, pipeline_stage: stage, entered_at: Time.current,
      custom_fields: { 'lead_metadata' => { 'form_slug' => form.slug } }
    )
  end

  context 'with crm_forms.read' do
    before { stub_auth(role_key: 'crm_manager', granted: %w[crm_forms.read]) }

    def request_leads
      get "/api/v1/crm_forms/#{form.id}/leads", headers: headers, as: :json
    end

    it 'returns a lead with its deal columns when the card is live (AC4: with item)' do
      contact = stamped_contact('Live')
      item = card_for(contact)

      request_leads

      expect(response).to have_http_status(:ok)
      lead = json_response['data'].find { |l| l['contact_id'] == contact.id }
      expect(lead).to be_present
      expect(lead['pipeline_item_id']).to eq(item.id)
      expect(lead['pipeline_id']).to eq(pipeline.id)
      expect(lead['pipeline_stage_id']).to eq(stage.id)
      expect(json_response['meta']['count']).to eq(1)
    end

    it 'still returns the lead after its card is deleted, deal columns degraded to nil (AC4: item deleted)' do
      contact = stamped_contact('Deleted')
      card_for(contact).destroy! # routine kanban delete of a real item

      request_leads

      expect(response).to have_http_status(:ok)
      lead = json_response['data'].find { |l| l['contact_id'] == contact.id }
      expect(lead).to be_present # the whole point of EVO-2207
      expect(lead['pipeline_item_id']).to be_nil
      expect(lead['pipeline_id']).to be_nil
      expect(lead['pipeline_stage_id']).to be_nil
      expect(lead['created_at']).to be_present # falls back to the contact's date
      expect(json_response['meta']['count']).to eq(1)
    end

    it 'returns a legacy lead that only carries form_slug on the item (AC4: legacy item-only)' do
      contact = Contact.create!(name: 'Legacy', email: "legacy-#{SecureRandom.hex(4)}@example.com")
      item = card_for(contact) # contact is NOT stamped; attribution lives on the item

      request_leads

      expect(response).to have_http_status(:ok)
      lead = json_response['data'].find { |l| l['contact_id'] == contact.id }
      expect(lead).to be_present
      expect(lead['pipeline_item_id']).to eq(item.id)
    end

    # The counter is the other half of the AC, and it reaches the screen through two
    # endpoints the leads list never touches: the form detail and the forms list.
    it 'keeps the detail counter after the card is deleted' do
      card_for(stamped_contact('Detail')).destroy!

      get "/api/v1/crm_forms/#{form.id}", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']['leads_count']).to eq(1)
    end

    it 'keeps the list counter after the card is deleted, per form' do
      card_for(stamped_contact('Listed')).destroy!
      other = CrmForm.create!(name: "Other #{SecureRandom.hex(4)}", default_pipeline: pipeline,
                              default_stage: stage, fields: form.fields)

      get '/api/v1/crm_forms', headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      counts = json_response['data'].to_h { |f| [f['id'], f['leads_count']] }
      expect(counts[form.id]).to eq(1)
      expect(counts[other.id]).to eq(0)
    end
  end

  context 'without crm_forms.read' do
    before { stub_auth(role_key: 'no_forms', granted: %w[crm_forms.create]) }

    it 'forbids the leads endpoint' do
      get "/api/v1/crm_forms/#{form.id}/leads", headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
