# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Webhooks::Sendgrid', type: :request do
  let(:fake_redis) { {} }

  def post_events(events)
    post '/webhooks/sendgrid', params: events.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }
  end

  def event(sg_event_id:, type: 'delivered', args: { contact_id: 'c-1', message_id: 'm-1', campaign_id: 'camp-1' })
    { 'sg_event_id' => sg_event_id, 'event' => type, 'email' => 'a@b.com', 'custom_args' => args }
  end

  before do
    allow(Redis::Alfred).to receive(:get) { |k| fake_redis[k] }
    allow(Redis::Alfred).to receive(:incr) { |k| fake_redis[k] = (fake_redis[k].to_i + 1).to_s }
    allow(Redis::Alfred).to receive(:set) do |k, v, **opts|
      next false if opts[:nx] && fake_redis.key?(k)

      fake_redis[k] = v.to_s
      true
    end
    # Status update and contact lookup are exercised in the unit spec; here we
    # only assert the controller contract, so keep them as cheap no-ops.
    allow(Message).to receive(:find_by).and_return(nil)
    allow(Contact).to receive(:find_by).and_return(nil)
  end

  describe 'POST /webhooks/sendgrid' do
    it 'returns 200 and claims the dedup key for a new event (AC1)' do
      post_events([event(sg_event_id: 'evt-new')])

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['received']).to eq(1)
      expect(fake_redis['sendgrid:event:evt-new']).to eq('1')
    end

    it 'drops a duplicate event on the second identical post (AC2)' do
      post_events([event(sg_event_id: 'evt-dup')])
      post_events([event(sg_event_id: 'evt-dup')])

      expect(response).to have_http_status(:ok)
      expect(fake_redis['sendgrid:events:duplicate_drops']).to eq('1')
    end

    it 'returns 200 and drops the event when custom_args are missing (AC4)' do
      allow(Rails.logger).to receive(:warn)
      post '/webhooks/sendgrid',
           params: [{ 'sg_event_id' => 'evt-noargs', 'event' => 'bounce' }].to_json,
           headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:ok)
      expect(fake_redis['sendgrid:events:missing_args_drops']).to eq('1')
    end

    it 'handles an array mixing new and duplicate events and returns 200 (AC5)' do
      post_events([event(sg_event_id: 'evt-a'), event(sg_event_id: 'evt-a'), event(sg_event_id: 'evt-b')])

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['received']).to eq(3)
    end

    it 'returns 200 even when an event raises during processing (AC5 resilience)' do
      allow(Sendgrid::EventProcessor).to receive(:new).and_raise(StandardError, 'boom')

      post_events([event(sg_event_id: 'evt-boom')])

      expect(response).to have_http_status(:ok)
    end

    it 'suppresses a real Contact and fires the status update on a bounce (AC3, end-to-end)' do
      # Exercise the real Redis::Alfred (MockRedis-backed in test) and a real
      # Contact DB write; only the heavy Message graph is doubled.
      allow(Redis::Alfred).to receive(:set).and_call_original
      allow(Redis::Alfred).to receive(:incr).and_call_original
      allow(Contact).to receive(:find_by).and_call_original

      contact = Contact.create!(name: 'SG Smoke', email: "sg-#{SecureRandom.hex(4)}@example.com")
      message = instance_double(Message)
      status_service = instance_double(Messages::StatusUpdateService, perform: true)
      allow(Message).to receive(:find_by).and_return(message)
      allow(Messages::StatusUpdateService).to receive(:new).and_return(status_service)

      post_events([event(sg_event_id: "evt-e2e-#{SecureRandom.hex(4)}", type: 'bounce',
                          args: { contact_id: contact.id, message_id: 'm-1', campaign_id: 'camp-1' })])

      expect(response).to have_http_status(:ok)
      expect(Messages::StatusUpdateService).to have_received(:new).with(message, 'failed', anything)
      contact.reload
      expect(contact.email_suppressed).to be(true)
      expect(contact.email_suppression_reason).to eq('bounce')
    end

    it 'accepts a single JSON object (non-array) payload and returns 200' do
      post '/webhooks/sendgrid',
           params: event(sg_event_id: 'evt-single').to_json,
           headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['received']).to eq(1)
    end
  end
end
