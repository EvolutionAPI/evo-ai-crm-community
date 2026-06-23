# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/labels', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) do
    {
      'X-Service-Token' => service_token
    }
  end

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  describe 'POST /api/v1/labels' do
    it 'creates label with single word title' do
      post '/api/v1/labels',
           params: { label: { title: 'vip' } },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:created)
      created_label = Label.find_by(title: 'vip')
      expect(created_label).to be_present
      expect(created_label.title).to eq('vip')

      expect(json_response['success']).to be(true)
      expect(json_response['data']).to include(
        'id' => created_label.id.to_s,
        'title' => 'vip',
        'color' => be_a(String),
        'created_at' => be_a(Integer),
        'updated_at' => be_a(Integer)
      )
      expect(json_response['meta']).to include('timestamp')
      expect(json_response['message']).to eq('Label created successfully')
    end

    it 'creates label with spaces in title' do
      post '/api/v1/labels',
           params: { label: { title: 'high priority' } },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:created)
      created_label = Label.find_by(title: 'high priority')
      expect(created_label).to be_present
      expect(created_label.title).to eq('high priority')

      expect(json_response['success']).to be(true)
      expect(json_response['data']).to include(
        'id' => created_label.id.to_s,
        'title' => 'high priority',
        'color' => be_a(String),
        'created_at' => be_a(Integer),
        'updated_at' => be_a(Integer)
      )
      expect(json_response['meta']).to include('timestamp')
      expect(json_response['message']).to eq('Label created successfully')
    end

    it 'normalizes leading and trailing spaces' do
      post '/api/v1/labels',
           params: { label: { title: '  high priority  ' } },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:created)
      created_label = Label.find_by(title: 'high priority')
      expect(created_label).to be_present
      expect(created_label.title).to eq('high priority')

      expect(json_response['success']).to be(true)
      expect(json_response['data']['title']).to eq('high priority')
      expect(json_response['meta']).to include('timestamp')
      expect(json_response['message']).to eq('Label created successfully')
    end

    it 'normalizes title to lowercase' do
      post '/api/v1/labels',
           params: { label: { title: 'HIGH PRIORITY' } },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:created)
      created_label = Label.find_by(title: 'high priority')
      expect(created_label).to be_present
      expect(created_label.title).to eq('high priority')

      expect(json_response['success']).to be(true)
      expect(json_response['data']['title']).to eq('high priority')
      expect(json_response['meta']).to include('timestamp')
      expect(json_response['message']).to eq('Label created successfully')
    end

    it 'creates label with multiple words and special characters' do
      post '/api/v1/labels',
           params: { label: { title: 'customer support - urgent' } },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:created)
      created_label = Label.find_by(title: 'customer support - urgent')
      expect(created_label).to be_present
      expect(created_label.title).to eq('customer support - urgent')

      expect(json_response['success']).to be(true)
      expect(json_response['data']['title']).to eq('customer support - urgent')
      expect(json_response['meta']).to include('timestamp')
      expect(json_response['message']).to eq('Label created successfully')
    end

    it 'enforces uniqueness' do
      Label.create!(title: 'duplicate label')

      post '/api/v1/labels',
           params: { label: { title: 'duplicate label' } },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response['success']).to be(false)
      expect(json_response['error']).to include(
        'code' => 'VALIDATION_ERROR',
        'message' => 'Validation failed'
      )
      expect(json_response['error']['details']).to be_an(Array)
      expect(json_response['error']['details'].first).to include(
        'field' => 'title',
        'messages' => be_an(Array),
        'full_messages' => be_an(Array)
      )
      expect(json_response['meta']).to include('timestamp', 'path', 'method')
    end

    it 'rejects empty title' do
      post '/api/v1/labels',
           params: { label: { title: '' } },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response['success']).to be(false)
      expect(json_response['error']).to include(
        'code' => 'VALIDATION_ERROR',
        'message' => 'Validation failed'
      )
      expect(json_response['error']['details']).to be_an(Array)
      expect(json_response['meta']).to include('timestamp', 'path', 'method')
    end

    it 'rejects title with only spaces' do
      post '/api/v1/labels',
           params: { label: { title: '   ' } },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response['success']).to be(false)
      expect(json_response['error']).to include(
        'code' => 'VALIDATION_ERROR',
        'message' => 'Validation failed'
      )
      expect(json_response['error']['details']).to be_an(Array)
      expect(json_response['meta']).to include('timestamp', 'path', 'method')
    end

    it 'rejects title with tab character' do
      post '/api/v1/labels',
           params: { label: { title: "label\twith\ttab" } },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response['success']).to be(false)
      expect(json_response['error']).to include(
        'code' => 'VALIDATION_ERROR',
        'message' => 'Validation failed'
      )
      expect(json_response['error']['details']).to be_an(Array)
      expect(json_response['meta']).to include('timestamp', 'path', 'method')
    end

    it 'rejects title with newline character' do
      post '/api/v1/labels',
           params: { label: { title: "label\nwith\nnewline" } },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response['success']).to be(false)
      expect(json_response['error']).to include(
        'code' => 'VALIDATION_ERROR',
        'message' => 'Validation failed'
      )
      expect(json_response['error']['details']).to be_an(Array)
      expect(json_response['meta']).to include('timestamp', 'path', 'method')
    end
  end

  describe 'GET /api/v1/labels' do
    it 'includes usage_count reflecting how many records use each label' do
      used = Label.create!(title: 'vip')
      Label.create!(title: 'unused')
      contact = Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com")
      contact.update!(label_list: ['vip'])

      get '/api/v1/labels', headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      used_data = json_response['data'].find { |l| l['id'] == used.id.to_s }
      unused_data = json_response['data'].find { |l| l['title'] == 'unused' }
      expect(used_data['usage_count']).to eq(1)
      expect(unused_data['usage_count']).to eq(0)
    end
  end

  describe 'DELETE /api/v1/labels/:id' do
    it 'deletes the label and cleans up orphaned taggings' do
      label = Label.create!(title: 'vip')
      contact = Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com")
      contact.update!(label_list: ['vip'])

      delete "/api/v1/labels/#{label.id}", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['success']).to be(true)
      expect(json_response['data']['id']).to eq(label.id.to_s)
      expect(Label.find_by(id: label.id)).to be_nil
      expect(Contact.tagged_with('vip')).to be_empty
      expect(contact.reload.label_list).not_to include('vip')
    end
  end

  describe 'PUT /api/v1/labels/:id' do
    let(:label) { Label.create!(title: 'original title') }

    it 'updates label title with spaces' do
      put "/api/v1/labels/#{label.id}",
          params: { label: { title: 'updated title with spaces' } },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:ok)
      label.reload
      expect(label.title).to eq('updated title with spaces')

      expect(json_response['success']).to be(true)
      expect(json_response['data']).to include(
        'id' => label.id.to_s,
        'title' => 'updated title with spaces',
        'color' => be_a(String),
        'created_at' => be_a(Integer),
        'updated_at' => be_a(Integer)
      )
      expect(json_response['meta']).to include('timestamp')
      expect(json_response['message']).to eq('Label updated successfully')
    end

    it 'normalizes spaces and case on update' do
      put "/api/v1/labels/#{label.id}",
          params: { label: { title: '  UPDATED TITLE  ' } },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:ok)
      label.reload
      expect(label.title).to eq('updated title')

      expect(json_response['success']).to be(true)
      expect(json_response['data']['title']).to eq('updated title')
      expect(json_response['meta']).to include('timestamp')
      expect(json_response['message']).to eq('Label updated successfully')
    end
  end
end
