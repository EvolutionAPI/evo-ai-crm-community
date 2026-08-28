# frozen_string_literal: true

require 'rails_helper'
require 'webmock'

# The channel token travels in the PATH of both public-connect endpoints, and
# handle() builds the error message out of that path. These exercise the real
# client so removing the redacted op label makes them fail.
RSpec.describe EvolutionHub::Client do
  # Scoped to this file: rails_helper does not load webmock, and enabling it
  # globally would change how every other spec sees the network.
  include WebMock::API

  subject(:client) { described_class.new }

  let(:channel_token) { 'super-secret-channel-token' }
  let(:hub_url) { MetaBaseUrl.hub_url }

  before do
    WebMock.enable!
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('EVOLUTION_HUB_API_KEY', nil).and_return('hub-api-key')
  end

  after { WebMock.disable! }

  # Records the JSON actually put on the wire so the example can assert on it
  # without webmock/rspec's matchers, which rails_helper does not load.
  def capture_signup_body
    sent = Struct.new(:value).new(nil)
    stub_request(:post, "#{hub_url}/api/v1/public/connect/#{channel_token}/whatsapp/connect")
      .with { |req| sent.value = JSON.parse(req.body) }
      .to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    sent
  end

  describe '#public_connect_info' do
    it 'sends the token in the path and returns the parsed payload' do
      stub_request(:get, "#{hub_url}/api/v1/public/connect/#{channel_token}")
        .to_return(status: 200, body: { 'can_connect' => true }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      expect(client.public_connect_info(channel_token)).to include('can_connect' => true)
    end

    it 'keeps the channel token out of the raised error message' do
      stub_request(:get, "#{hub_url}/api/v1/public/connect/#{channel_token}")
        .to_return(status: 404, body: '{}', headers: { 'Content-Type' => 'application/json' })

      expect { client.public_connect_info(channel_token) }
        .to raise_error(EvolutionHub::Client::RequestError) { |e|
          expect(e.message).not_to include(channel_token)
          expect(e.message).to include('/api/v1/public/connect/:token')
        }
    end
  end

  describe '#public_whatsapp_connect' do
    let(:signup) do
      { phone_number_id: '111', waba_id: '222', business_id: '333',
        auth_code: 'code-abc', connection_mode: 'meta' }
    end

    it 'posts only the signup fields the Hub accepts' do
      sent = capture_signup_body

      client.public_whatsapp_connect(channel_token, signup.merge(evil: 'ignored'))

      expect(sent.value).to eq(signup.transform_keys(&:to_s))
    end

    it 'drops blank optional fields instead of sending nils' do
      sent = capture_signup_body

      client.public_whatsapp_connect(channel_token,
                                     { phone_number_id: '111', waba_id: '222', connection_mode: 'meta' })

      expect(sent.value).to eq({ 'phone_number_id' => '111', 'waba_id' => '222', 'connection_mode' => 'meta' })
    end

    it 'keeps the channel token out of the raised error message' do
      stub_request(:post, "#{hub_url}/api/v1/public/connect/#{channel_token}/whatsapp/connect")
        .to_return(status: 400, body: '{}', headers: { 'Content-Type' => 'application/json' })

      expect { client.public_whatsapp_connect(channel_token, signup) }
        .to raise_error(EvolutionHub::Client::RequestError) { |e|
          expect(e.message).not_to include(channel_token)
          expect(e.message).to include('/api/v1/public/connect/:token/whatsapp/connect')
        }
    end

    it 'preserves the structured Hub error code' do
      stub_request(:post, "#{hub_url}/api/v1/public/connect/#{channel_token}/whatsapp/connect")
        .to_return(status: 403,
                   body: { error: { code: 'PLAN_FORBIDS_SHARED', message: 'plano nao permite' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      expect { client.public_whatsapp_connect(channel_token, signup) }
        .to raise_error(EvolutionHub::Client::RequestError) { |e| expect(e.code).to eq('PLAN_FORBIDS_SHARED') }
    end
  end
end
