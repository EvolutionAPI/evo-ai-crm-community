# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# These calls invoke a controller action, not ActiveRecord#create.
# rubocop:disable Rails/SaveBang
RSpec.describe Api::V1::Evolution::AuthorizationsController, type: :controller do
  let(:api_url) { 'https://evolution.example.com' }
  let(:instance_name) { 'support' }
  let(:fetch_url) { "#{api_url}/instance/fetchInstances?instanceName=#{instance_name}" }
  let(:created_instance) { { 'instance' => { 'instanceName' => instance_name } } }

  before do
    controller.params = ActionController::Parameters.new(
      authorization: {
        api_url: api_url, admin_token: 'test-admin-key', instance_name: instance_name,
        phone_number: '15555550123'
      }
    )
    allow(controller).to receive(:check_server_status).and_return('version' => '2.3.7')
    allow(controller).to receive(:success_response)
    allow(controller).to receive(:error_response)
  end

  it 'creates an instance when the filtered lookup returns an empty list' do
    stub_request(:get, fetch_url).with(headers: { 'apikey' => 'test-admin-key' }).to_return(body: '[]')
    expect(controller).to receive(:create_instance).and_return(created_instance)
    expect(controller).to receive(:success_response).with(hash_including(data: hash_including(instance: created_instance)))

    controller.create
  end

  it 'creates an instance when the server explicitly reports it missing' do
    stub_request(:get, fetch_url).to_return(status: 404)
    expect(controller).to receive(:create_instance).and_return(created_instance)

    controller.create
  end

  it 'rejects a name collision without deleting or replacing the existing instance' do
    stub_request(:get, fetch_url).to_return(body: [{ 'name' => instance_name }].to_json)
    deletion = stub_request(:delete, "#{api_url}/instance/delete/#{instance_name}")
    expect(controller).not_to receive(:create_instance)
    expect(controller).to receive(:error_response).with(
      ApiErrorCodes::EXTERNAL_SERVICE_ERROR, /Instance already exists/, status: :unprocessable_entity
    )

    controller.create

    expect(deletion).not_to have_been_requested
  end

  [401, 403, 500, 503].each do |status|
    it "does not create an instance when lookup returns HTTP #{status}" do
      stub_request(:get, fetch_url).to_return(status: status, body: '{}')
      expect(controller).not_to receive(:create_instance)
      expect(controller).to receive(:error_response).with(
        ApiErrorCodes::EXTERNAL_SERVICE_ERROR, /Failed to fetch instances/, status: :unprocessable_entity
      )

      controller.create
    end
  end

  ['not json', '{}', 'null'].each do |body|
    it "does not create an instance on an invalid lookup response: #{body}" do
      stub_request(:get, fetch_url).to_return(body: body)
      expect(controller).not_to receive(:create_instance)
      expect(controller).to receive(:error_response).with(
        ApiErrorCodes::EXTERNAL_SERVICE_ERROR, /Invalid response/, status: :unprocessable_entity
      )

      controller.create
    end
  end

  it 'does not create an instance when lookup times out' do
    stub_request(:get, fetch_url).to_timeout
    expect(controller).not_to receive(:create_instance)
    expect(controller).to receive(:error_response).with(
      ApiErrorCodes::EXTERNAL_SERVICE_ERROR, anything, status: :unprocessable_entity
    )

    controller.create
  end
end

# rubocop:enable Rails/SaveBang
