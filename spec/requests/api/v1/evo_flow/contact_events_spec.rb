# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'GET /api/v1/contacts/:contact_id/events', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:integration_key) { 'spec-integration-key' }
  let(:headers) { { 'X-Service-Token' => service_token } }
  let(:contact_id) { SecureRandom.uuid }
  let(:base_url) { ENV.fetch('EVO_FLOW_API_URL', 'http://evo-flow:3000/api/v1') }
  let(:events_url) { "#{base_url}/contacts/#{contact_id}/events" }

  around do |example|
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    ENV['AUTH_APIKEY_INTEGRATION_LOCAL'] = integration_key
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache.clear
    Rails.cache = original_cache
    ENV.delete('EVOAI_CRM_API_TOKEN')
    ENV.delete('AUTH_APIKEY_INTEGRATION_LOCAL')
    Current.reset
  end

  def json_response
    response.parsed_body
  end

  describe 'AC1 — happy path proxy' do
    it 'proxies to evo-flow with limit=10 and returns events/pagination' do
      stub = stub_request(:get, events_url)
             .with(query: { 'limit' => '10' })
             .to_return(
               status: 200,
               body: { events: [], pagination: { hasNext: false, nextCursor: nil, limit: 10 } }.to_json,
               headers: { 'Content-Type' => 'application/json' }
             )

      get "/api/v1/contacts/#{contact_id}/events", params: { limit: 10 }, headers: headers

      expect(stub).to have_been_requested
      expect(response).to have_http_status(:ok)
      expect(json_response).to include('events', 'pagination')
    end
  end

  describe 'AC2 — enrich campaign_name' do
    it 'enriches each event with campaign_name from Postgres' do
      campaign = Campaign.create!(title: 'BF', name: "black-friday-#{SecureRandom.hex(2)}", type: 'Default')
      stub_request(:get, events_url)
        .to_return(
          status: 200,
          body: { events: [{ id: 'e1', properties: { 'campaign_id' => campaign.id } }] }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get "/api/v1/contacts/#{contact_id}/events", headers: headers

      expect(response).to have_http_status(:ok)
      expect(json_response.dig('events', 0, 'enriched', 'campaign_name')).to eq(campaign.name)
    end
  end

  describe 'AC3 — cache (Rails.cache hit)' do
    it 'hits Postgres exactly once across two requests and both responses are enriched' do
      campaign = Campaign.create!(title: 'BF', name: "cached-#{SecureRandom.hex(2)}", type: 'Default')
      stub_request(:get, events_url)
        .to_return(
          status: 200,
          body: { events: [{ properties: { 'campaign_id' => campaign.id } }] }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect(Campaign).to receive(:find_by).once.and_call_original

      get "/api/v1/contacts/#{contact_id}/events", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json_response.dig('events', 0, 'enriched', 'campaign_name')).to eq(campaign.name)

      get "/api/v1/contacts/#{contact_id}/events", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json_response.dig('events', 0, 'enriched', 'campaign_name')).to eq(campaign.name)
    end
  end

  describe 'AC4 — degradação 5xx' do
    it 'returns 200 with events:[] degraded:true on upstream 503 (Client already logs :error; controller does not double-log)' do
      stub_request(:get, events_url).to_return(status: 503, body: 'upstream down')
      expect(Rails.logger).not_to receive(:warn)

      get "/api/v1/contacts/#{contact_id}/events", headers: headers

      expect(response).to have_http_status(:ok)
      expect(json_response).to eq('events' => [], 'degraded' => true)
    end
  end

  describe 'AC5 — propagação 4xx (404)' do
    it 'propagates 404 with upstream body' do
      stub_request(:get, events_url)
        .to_return(
          status: 404,
          body: { error: 'not found' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get "/api/v1/contacts/#{contact_id}/events", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(json_response).to include('error' => 'not found')
    end
  end

  describe 'AC6 — auth' do
    it 'returns 401 without any auth header' do
      get "/api/v1/contacts/#{contact_id}/events"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'AC7 — snake_case → camelCase' do
    it 'translates whitelisted filters and drops non-whitelisted ones' do
      stub = stub_request(:get, events_url)
             .with(query: hash_including(
               'eventType' => 'track',
               'campaignId' => '7',
               'occurredAfter' => '2026-05-01'
             ))
             .to_return(status: 200, body: { events: [] }.to_json,
                        headers: { 'Content-Type' => 'application/json' })

      get "/api/v1/contacts/#{contact_id}/events",
          params: { event_type: 'track', campaign_id: '7', occurred_after: '2026-05-01', foo: 'bar' },
          headers: headers

      expect(stub).to have_been_requested
      expect(WebMock).not_to have_requested(:get, events_url).with(query: hash_including('foo'))
    end
  end

  describe 'AC8 — enrich channel_label' do
    it 'maps known channel to display label' do
      stub_request(:get, events_url)
        .to_return(
          status: 200,
          body: { events: [{ properties: { 'channel' => 'whatsapp' } }] }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get "/api/v1/contacts/#{contact_id}/events", headers: headers

      expect(response).to have_http_status(:ok)
      expect(json_response.dig('events', 0, 'enriched', 'channel_label')).to eq('WhatsApp')
    end

    it 'maps both facebook and facebook_page to Facebook' do
      stub_request(:get, events_url)
        .to_return(
          status: 200,
          body: { events: [
            { properties: { 'channel' => 'facebook' } },
            { properties: { 'channel' => 'facebook_page' } }
          ] }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get "/api/v1/contacts/#{contact_id}/events", headers: headers

      expect(json_response.dig('events', 0, 'enriched', 'channel_label')).to eq('Facebook')
      expect(json_response.dig('events', 1, 'enriched', 'channel_label')).to eq('Facebook')
    end

    it 'falls back to the original key for unknown channel' do
      stub_request(:get, events_url)
        .to_return(
          status: 200,
          body: { events: [{ properties: { 'channel' => 'foo' } }] }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get "/api/v1/contacts/#{contact_id}/events", headers: headers

      expect(json_response.dig('events', 0, 'enriched', 'channel_label')).to eq('foo')
    end
  end

  describe 'AC9 — enrich agent_name' do
    it 'enriches with User.name from Postgres' do
      agent = User.create!(name: 'Daniela', email: "daniela-#{SecureRandom.hex(2)}@example.com")
      stub_request(:get, events_url)
        .to_return(
          status: 200,
          body: { events: [{ properties: { 'agent_id' => agent.id } }] }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get "/api/v1/contacts/#{contact_id}/events", headers: headers

      expect(json_response.dig('events', 0, 'enriched', 'agent_name')).to eq('Daniela')
    end
  end

  describe 'enrich payload hygiene' do
    it "omits the 'enriched' key entirely when the event has no enrichable property" do
      stub_request(:get, events_url)
        .to_return(
          status: 200,
          body: { events: [{ id: 'e1', properties: { 'foo' => 'bar' } }] }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get "/api/v1/contacts/#{contact_id}/events", headers: headers

      expect(response).to have_http_status(:ok)
      expect(json_response.dig('events', 0)).not_to have_key('enriched')
    end

    it 'omits nil enrich values instead of returning enriched.campaign_name = nil' do
      missing_id = SecureRandom.uuid
      stub_request(:get, events_url)
        .to_return(
          status: 200,
          body: { events: [{ properties: { 'campaign_id' => missing_id, 'channel' => 'whatsapp' } }] }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get "/api/v1/contacts/#{contact_id}/events", headers: headers

      enriched = json_response.dig('events', 0, 'enriched')
      expect(enriched).to eq('channel_label' => 'WhatsApp')
      expect(enriched).not_to have_key('campaign_name')
    end
  end

  describe 'AC10 — network failure degrades to events:[]' do
    it 'degrades on timeout (EvoFlow::HTTPError with code=nil) and emits a controller-level warn' do
      stub_request(:get, events_url).to_timeout
      expect(Rails.logger).to receive(:warn).with(/degraded.*code=nil/)

      get "/api/v1/contacts/#{contact_id}/events", headers: headers

      expect(response).to have_http_status(:ok)
      expect(json_response).to eq('events' => [], 'degraded' => true)
    end
  end
end
