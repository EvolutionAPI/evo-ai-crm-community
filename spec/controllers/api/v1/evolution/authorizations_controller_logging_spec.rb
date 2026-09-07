# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Api::V1::Evolution::AuthorizationsController, type: :controller do
  let(:api_url) { 'https://evolution.example.com' }
  let(:admin_token) { 'test-admin-credential-do-not-log' }
  let(:instance_token) { 'test-instance-credential-do-not-log' }
  let(:output) { StringIO.new }

  before do
    allow(Rails).to receive(:logger).and_return(Logger.new(output))
    allow(controller).to receive(:webhook_url).and_return('https://crm.example.com/webhooks/evolution')
  end

  it 'keeps credentials in the outgoing request and returned result, without logging either' do
    stub_request(:post, "#{api_url}/instance/create")
      .with(headers: { 'apikey' => admin_token })
      .to_return(body: { hash: instance_token }.to_json)

    result = controller.send(:create_instance, api_url, admin_token, 'support', '15555550123', {})

    expect(result['hash']).to eq(instance_token)
    expect(output.string).not_to include(admin_token, instance_token)
    expect(output.string).to include('response code: 200')
  end

  it 'does not log credentials returned by an instance lookup' do
    stub_request(:get, "#{api_url}/instance/fetchInstances?instanceName=support")
      .to_return(body: [{ token: instance_token }].to_json)

    controller.send(:fetch_instances, api_url, admin_token, 'support')

    expect(output.string).not_to include(instance_token)
  end

  it 'does not include a provider error body in logs or exception messages' do
    stub_request(:post, "#{api_url}/instance/create")
      .to_return(status: 500, body: { error: "request used #{admin_token}" }.to_json)

    expect do
      controller.send(:create_instance, api_url, admin_token, 'support', '15555550123', {})
    end.to raise_error(/Status: 500/) { |error| expect(error.message).not_to include(admin_token) }
    expect(output.string).not_to include(admin_token)
  end

  it 'does not log malformed response bodies or parser excerpts containing credentials' do
    stub_request(:post, "#{api_url}/instance/create").to_return(body: "not-json: #{instance_token}")

    expect do
      controller.send(:create_instance, api_url, admin_token, 'support', '15555550123', {})
    end.to raise_error('Invalid response from Evolution API create instance endpoint')
    expect(output.string).not_to include(instance_token)
  end

  { apply_proxy_settings: 'proxy', apply_instance_settings: 'settings' }.each do |method, endpoint|
    it "keeps failure status diagnostics without logging the #{endpoint} response body" do
      stub_request(:post, "#{api_url}/#{endpoint}/set/support")
        .to_return(status: 500, body: "request used #{admin_token}")

      controller.send(method, api_url, admin_token, 'support', { 'enabled' => true })

      expect(output.string).to include('Status: 500')
      expect(output.string).not_to include(admin_token)
    end
  end

  it 'does not log submitted credentials when required parameters are missing' do
    controller.params = ActionController::Parameters.new(authorization: { api_url: api_url, admin_token: admin_token })
    allow(controller).to receive(:error_response)

    controller.create # rubocop:disable Rails/SaveBang -- controller action, not ActiveRecord

    expect(output.string).not_to include(admin_token)
    expect(output.string).to include('Missing parameters: instance_name, phone_number')
  end
end
