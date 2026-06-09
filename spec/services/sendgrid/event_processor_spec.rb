# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sendgrid::EventProcessor do
  subject(:processor) { described_class.new(event) }

  let(:fake_redis) { {} }
  let(:message) { instance_double(Message) }
  let(:contact) { instance_double(Contact, update!: true) }
  let(:status_service) { instance_double(Messages::StatusUpdateService, perform: true) }

  let(:custom_args) { { 'contact_id' => 'c-1', 'message_id' => 'm-1', 'campaign_id' => 'camp-1' } }
  let(:event) { { 'sg_event_id' => 'evt-1', 'event' => 'delivered', 'email' => 'a@b.com', 'custom_args' => custom_args } }

  before do
    # In-memory Redis::Alfred stub with NX/EX-aware #set (repo convention,
    # mirrors spec/workers/evo_flow/backfill_contact_events_worker_spec.rb).
    allow(Redis::Alfred).to receive(:get) { |k| fake_redis[k] }
    allow(Redis::Alfred).to receive(:incr) { |k| fake_redis[k] = (fake_redis[k].to_i + 1).to_s }
    allow(Redis::Alfred).to receive(:delete) { |k| fake_redis.delete(k) }
    allow(Redis::Alfred).to receive(:set) do |k, v, **opts|
      next false if opts[:nx] && fake_redis.key?(k)

      fake_redis[k] = v.to_s
      true
    end

    allow(Message).to receive(:find_by).and_return(message)
    allow(Contact).to receive(:find_by).and_return(contact)
    allow(Messages::StatusUpdateService).to receive(:new).and_return(status_service)
  end

  describe 'deduplication (AC1, AC2)' do
    it 'claims the sg_event_id with a 24h TTL on first sight and processes once' do
      expect(processor.process).to eq(:processed)
      expect(Redis::Alfred).to have_received(:set).with('sendgrid:event:evt-1', 1, nx: true, ex: 24.hours.to_i)
    end

    it 'drops the second identical event and increments the duplicate metric' do
      described_class.new(event).process
      expect(described_class.new(event).process).to eq(:duplicate)
      expect(fake_redis['sendgrid:events:duplicate_drops']).to eq('1')
    end

    it 'does not re-run the status update for a duplicate event' do
      described_class.new(event).process
      described_class.new(event).process
      expect(Messages::StatusUpdateService).to have_received(:new).once
    end
  end

  describe 'missing custom_args (AC4)' do
    %w[contact_id message_id campaign_id].each do |missing_key|
      it "drops the event when #{missing_key} is missing and logs + increments metric" do
        event['custom_args'] = custom_args.except(missing_key)
        allow(Rails.logger).to receive(:warn)

        expect(processor.process).to eq(:missing_args)
        expect(fake_redis['sendgrid:events:missing_args_drops']).to eq('1')
        expect(Rails.logger).to have_received(:warn).with(/missing custom_args/)
        expect(Messages::StatusUpdateService).not_to have_received(:new)
      end
    end

    it 'drops the event when custom_args is absent entirely' do
      event.delete('custom_args')
      expect(processor.process).to eq(:missing_args)
    end
  end

  describe 'event -> status mapping (AC6)' do
    {
      'delivered' => 'delivered',
      'open' => 'read',
      'click' => 'read',
      'bounce' => 'failed',
      'dropped' => 'failed',
      'spam_report' => 'failed'
    }.each do |sendgrid_event, internal_status|
      it "maps #{sendgrid_event} -> #{internal_status} via Messages::StatusUpdateService" do
        event['event'] = sendgrid_event
        processor.process
        expect(Messages::StatusUpdateService).to have_received(:new).with(message, internal_status, anything)
      end
    end

    it 'increments the per-type metric for each processed event' do
      event['event'] = 'open'
      processor.process
      expect(fake_redis['sendgrid:events:type:open']).to eq('1')
    end

    it 'passes the bounce reason as external_error for failed statuses' do
      event['event'] = 'bounce'
      event['reason'] = '550 mailbox unavailable'
      processor.process
      expect(Messages::StatusUpdateService).to have_received(:new).with(message, 'failed', '550 mailbox unavailable')
    end

    it 'skips the status update when the message cannot be resolved' do
      allow(Message).to receive(:find_by).and_return(nil)
      allow(Rails.logger).to receive(:warn)
      expect(processor.process).to eq(:processed)
      expect(Messages::StatusUpdateService).not_to have_received(:new)
    end
  end

  describe 'contact suppression (AC3)' do
    %w[bounce dropped spam_report unsubscribe].each do |negative_event|
      it "suppresses the contact email on #{negative_event}" do
        event['event'] = negative_event
        processor.process
        expect(contact).to have_received(:update!).with(email_suppressed: true, email_suppression_reason: negative_event)
      end
    end

    it 'does not suppress the contact on positive events' do
      event['event'] = 'delivered'
      processor.process
      expect(contact).not_to have_received(:update!)
    end
  end

  describe 'unsubscribe (suppression-only, no status transition)' do
    it 'suppresses the contact but does not call the status update service' do
      event['event'] = 'unsubscribe'
      processor.process
      expect(contact).to have_received(:update!).with(email_suppressed: true, email_suppression_reason: 'unsubscribe')
      expect(Messages::StatusUpdateService).not_to have_received(:new)
    end
  end

  describe 'transient failure (M1)' do
    it 'releases the dedup claim so a resend can be retried when processing raises' do
      event['event'] = 'bounce'
      allow(Contact).to receive(:find_by).and_raise(StandardError, 'db down')

      expect { processor.process }.to raise_error(StandardError)
      expect(fake_redis).not_to have_key('sendgrid:event:evt-1')
    end
  end

  describe 'missing sg_event_id (L1)' do
    it 'processes without dedup and logs a warning' do
      event.delete('sg_event_id')
      allow(Rails.logger).to receive(:warn)

      expect(processor.process).to eq(:processed)
      expect(Rails.logger).to have_received(:warn).with(/without sg_event_id/)
      expect(Redis::Alfred).not_to have_received(:set)
    end
  end

  describe 'metrics' do
    it 'always increments the total counter' do
      processor.process
      expect(fake_redis['sendgrid:events:total']).to eq('1')
    end
  end
end
