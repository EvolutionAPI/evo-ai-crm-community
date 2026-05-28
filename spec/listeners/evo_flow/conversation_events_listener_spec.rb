# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe EvoFlow::ConversationEventsListener do
  let(:listener) { described_class.new }
  let(:created_at) { Time.utc(2026, 5, 20, 10, 0, 0) }
  let(:inbox) { instance_double(Inbox, name: 'Support', channel_type: 'Channel::WebWidget') }
  let(:updated_at) { Time.utc(2026, 5, 20, 10, 30, 0) }
  let(:conversation) do
    instance_double(
      Conversation,
      id: 100,
      contact_id: 42,
      inbox_id: '550e8400-e29b-41d4-a716-446655440007',
      inbox: inbox,
      created_at: created_at,
      updated_at: updated_at
    )
  end
  let(:fixed_digest) { 'fixed-digest' }

  before do
    Sidekiq::Testing.fake!
    EvoFlow::PublishEventWorker.clear
    allow(EvoFlow::PayloadBuilder).to receive(:message_id_for).and_return(fixed_digest)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return('test-key')
  end

  after { EvoFlow::PublishEventWorker.clear }

  describe '#conversation_created' do
    let(:payload) { { conversation: conversation } }

    it 'enqueues a track event for conversation.created (AC6)' do
      listener.conversation_created(data: payload)

      job = EvoFlow::PublishEventWorker.jobs.last
      expect(EvoFlow::PublishEventWorker.jobs.size).to eq(1)
      expect(job['args'][0]).to eq('/events/track')

      sent = job['args'][1]
      expect(sent['event']).to eq('conversation.created')
      expect(sent['contactId']).to eq('42')
      expect(sent['messageId']).to eq(fixed_digest)
      expect(sent['properties']).to include(
        'conversation_id' => 100,
        'inbox_id' => '550e8400-e29b-41d4-a716-446655440007',
        'inbox_name' => 'Support',
        'channel_type' => 'Channel::WebWidget',
        'source' => 'conversation_management'
      )
    end

    context 'when ENV is absent (AC12)' do
      before { allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return(nil) }

      it 'does not enqueue and emits no error log' do
        expect(Rails.logger).not_to receive(:error)
        listener.conversation_created(data: payload)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when called with an EventDispatcher payload (AC13)' do
      it 'returns early and does not enqueue' do
        event = Struct.new(:data).new(payload)
        listener.conversation_created(event)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when conversation is missing (AC14)' do
      it 'logs an error and does not enqueue' do
        expect(Rails.logger).to receive(:error).with(/conversation_created.*conversation is nil/)
        listener.conversation_created(data: {})
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when build_track raises (AC15)' do
      it 'logs the error and returns nil' do
        allow(EvoFlow::PayloadBuilder).to receive(:build_track).and_raise(ArgumentError, 'boom')

        expect(Rails.logger).to receive(:error).with(/conversation_created failed: ArgumentError: boom/)
        expect(listener.conversation_created(data: payload)).to be_nil
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    # F7: Redis outage during perform_async must be swallowed without
    # propagating (Wisper broadcast would otherwise stop downstream listeners).
    context 'when perform_async raises Redis::BaseConnectionError (F6/F7)' do
      it 'tags [enqueue-loss] at error level and does not propagate' do
        stub_const('Redis::BaseConnectionError', Class.new(StandardError)) unless defined?(Redis::BaseConnectionError)
        allow(EvoFlow::PublishEventWorker).to receive(:perform_async)
          .and_raise(Redis::BaseConnectionError, 'redis down')

        expect(Rails.logger).to receive(:error).with(/\[EvoFlow\]\[enqueue-loss\].*Redis::BaseConnectionError/)
        expect { listener.conversation_created(data: payload) }.not_to raise_error
      end
    end

    # F12: AC17 idempotency on conversation_created.
    describe 'message_id idempotency (AC17)' do
      it 'produces identical messageId for two firings of the same record event' do
        allow(EvoFlow::PayloadBuilder).to receive(:message_id_for).and_call_original

        2.times { listener.conversation_created(data: payload) }

        jobs = EvoFlow::PublishEventWorker.jobs
        expect(jobs.size).to eq(2)
        expect(jobs[0]['args'][1]['messageId']).to eq(jobs[1]['args'][1]['messageId'])
      end
    end
  end

  # AC2: conversation.resolved. F-1: the model now publishes a Wisper-direct hash
  # in addition to the Dispatcher path; the handler accepts the hash and rejects
  # the Events::Base envelope to avoid double-publishing.
  describe '#conversation_resolved' do
    let(:event_data) { { conversation: conversation, performed_by: nil, changed_attributes: { status: %w[open resolved] } } }
    let(:wisper_payload) { { data: event_data } }

    it 'enqueues a track event for conversation.resolved (AC2)' do
      listener.conversation_resolved(wisper_payload)

      job = EvoFlow::PublishEventWorker.jobs.last
      expect(EvoFlow::PublishEventWorker.jobs.size).to eq(1)
      expect(job['args'][0]).to eq('/events/track')

      sent = job['args'][1]
      expect(sent['event']).to eq('conversation.resolved')
      expect(sent['contactId']).to eq('42')
      expect(sent['properties']).to include(
        'conversation_id' => 100,
        'inbox_id' => '550e8400-e29b-41d4-a716-446655440007',
        'channel_type' => 'Channel::WebWidget',
        'resolution_time_seconds' => 1800,
        'source' => 'conversation_management'
      )
    end

    context 'when ENV is absent' do
      before do
        allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return(nil)
        allow(ENV).to receive(:[]).with('EVO_FLOW_ENABLED').and_return(nil)
      end

      it 'does not enqueue' do
        listener.conversation_resolved(wisper_payload)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    # F-1: the Dispatcher fires Sync + Async, each publishing an Events::Base
    # envelope to global Wisper subscribers. The handler must reject these so
    # the listener processes only once (from the Wisper-direct producer).
    context 'when called with an Events::Base envelope (Dispatcher path)' do
      it 'returns early and does not enqueue' do
        event = Events::Base.new('conversation.resolved', Time.zone.now, event_data)
        listener.conversation_resolved(event)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when conversation is missing' do
      it 'logs an error and does not enqueue' do
        expect(Rails.logger).to receive(:error).with(/conversation_resolved.*conversation is nil/)
        listener.conversation_resolved(data: {})
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    describe 'message_id idempotency' do
      it 'produces identical messageId for two firings' do
        allow(EvoFlow::PayloadBuilder).to receive(:message_id_for).and_call_original

        2.times { listener.conversation_resolved(wisper_payload) }

        jobs = EvoFlow::PublishEventWorker.jobs
        expect(jobs.size).to eq(2)
        expect(jobs[0]['args'][1]['messageId']).to eq(jobs[1]['args'][1]['messageId'])
      end
    end
  end

  # M1: AC1 integration spec. Drive the real model write
  # path (`conversation.update!(status: 'resolved')`) so both the Wisper-direct
  # publish from the model AND the Sync+Async dispatchers fire. Assert that
  # exactly ONE job lands in EvoFlow::PublishEventWorker — proving the
  # `return if data.respond_to?(:data)` guard rejects the two Events::Base
  # envelopes from the Dispatcher path.
  describe 'AC1 integration: end-to-end dedup via real model update' do
    let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
    let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
    let(:inbox) { Inbox.create!(name: 'M1 Inbox', channel: channel) }
    let(:contact) { Contact.create!(name: 'M1', email: "m1-#{SecureRandom.hex(4)}@test.com") }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let(:open_conversation) do
      Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: 'open')
    end

    it 'enqueues exactly 1 job with event_name=conversation.resolved' do
      open_conversation # ensure it exists with status=open

      EvoFlow::PublishEventWorker.clear
      open_conversation.update!(status: 'resolved')

      jobs = EvoFlow::PublishEventWorker.jobs.select { |j| j['args'][1]['event'] == 'conversation.resolved' }
      expect(jobs.size).to eq(1)

      sent = jobs.first['args'][1]
      expect(sent['contactId']).to eq(contact.id.to_s)
      expect(sent['messageId']).to be_present
      expect(sent['properties']).to include(
        'conversation_id' => open_conversation.id,
        'inbox_id' => inbox.id
      )
    end
  end
end
