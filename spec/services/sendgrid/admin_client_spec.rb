# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Sendgrid::AdminClient do
  subject(:client) { described_class.new(api_key) }

  let(:api_key) { 'SG.test-key' }
  let(:scopes_url) { 'https://api.sendgrid.com/v3/scopes' }
  let(:webhook_url) { 'https://api.sendgrid.com/v3/user/webhooks/event/settings' }
  let(:callback_url) { 'https://crm.example.com/webhooks/sendgrid' }

  describe '#smoke_test!' do
    it 'returns true and sends the key as a Bearer token when SendGrid accepts it' do
      stub = stub_request(:get, scopes_url)
             .with(headers: { 'Authorization' => "Bearer #{api_key}" })
             .to_return(status: 200, body: { scopes: ['mail.send'] }.to_json)

      expect(client.smoke_test!).to be(true)
      expect(stub).to have_been_requested
    end

    [401, 403].each do |code|
      it "raises InvalidApiKeyError on #{code}" do
        stub_request(:get, scopes_url).to_return(status: code, body: '{}')

        expect { client.smoke_test! }.to raise_error(Sendgrid::InvalidApiKeyError)
      end
    end

    it 'raises ServiceUnavailableError on a 5xx' do
      stub_request(:get, scopes_url).to_return(status: 503, body: 'down')

      expect { client.smoke_test! }.to raise_error(Sendgrid::ServiceUnavailableError)
    end

    it 'raises ServiceUnavailableError on a network failure' do
      stub_request(:get, scopes_url).to_timeout

      expect { client.smoke_test! }.to raise_error(Sendgrid::ServiceUnavailableError)
    end
  end

  describe '#upsert_event_webhook!' do
    it 'enables the callback url with exactly the eleven scoped events' do
      stub_request(:patch, webhook_url).to_return(status: 200, body: '{}')

      client.upsert_event_webhook!(callback_url: callback_url)

      expect(
        a_request(:patch, webhook_url).with do |req|
          body = JSON.parse(req.body)
          body['enabled'] == true && body['url'] == callback_url &&
            described_class::WEBHOOK_EVENTS.all? { |event| body[event] == true }
        end
      ).to have_been_made
    end

    it 'raises ServiceUnavailableError on a 5xx' do
      stub_request(:patch, webhook_url).to_return(status: 500, body: 'oops')

      expect { client.upsert_event_webhook!(callback_url: callback_url) }
        .to raise_error(Sendgrid::ServiceUnavailableError)
    end
  end
end
