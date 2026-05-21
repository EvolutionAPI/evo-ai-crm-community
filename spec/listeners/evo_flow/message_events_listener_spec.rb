# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe EvoFlow::MessageEventsListener do
  let(:listener) { described_class.new }
  let(:created_at) { Time.utc(2026, 5, 20, 10, 0, 0) }
  let(:inbox) { instance_double(Inbox, channel_type: 'Channel::WebWidget') }
  let(:conversation) { instance_double(Conversation, contact_id: 42, inbox: inbox) }
  let(:updated_at) { Time.utc(2026, 5, 20, 10, 5, 0) }
  let(:message) do
    instance_double(
      Message,
      id: 555,
      conversation: conversation,
      conversation_id: 100,
      message_type: 'incoming',
      content_type: 'text',
      content: 'hello',
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

  describe '#message_created' do
    let(:payload) { { message: message } }

    it 'enqueues a track event for message.created (AC7)' do
      listener.message_created(data: payload)

      job = EvoFlow::PublishEventWorker.jobs.last
      expect(EvoFlow::PublishEventWorker.jobs.size).to eq(1)
      expect(job['args'][0]).to eq('/events/track')

      sent = job['args'][1]
      expect(sent['event']).to eq('message.created')
      expect(sent['contactId']).to eq('42')
      expect(sent['properties']).to include(
        'message_id' => 555,
        'conversation_id' => 100,
        'message_type' => 'incoming',
        'content_type' => 'text',
        'content' => 'hello',
        'channel_type' => 'Channel::WebWidget',
        'source' => 'messaging'
      )
    end

    context 'when inbox is missing (AC8)' do
      let(:conversation) { instance_double(Conversation, contact_id: 42, inbox: nil) }

      it 'logs a warn and does not enqueue' do
        expect(Rails.logger).to receive(:warn).with(/inbox missing for message 555/)
        listener.message_created(data: payload)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when ENV is absent (AC12)' do
      before { allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return(nil) }

      it 'does not enqueue and emits no error log' do
        expect(Rails.logger).not_to receive(:error)
        listener.message_created(data: payload)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when called with an EventDispatcher payload (AC13)' do
      it 'returns early and does not enqueue' do
        event = Struct.new(:data).new(payload)
        listener.message_created(event)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when message is missing (AC14)' do
      it 'logs an error and does not enqueue' do
        expect(Rails.logger).to receive(:error).with(/message_created.*message is nil/)
        listener.message_created(data: {})
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when build_track raises (AC15)' do
      it 'logs the error and returns nil' do
        allow(EvoFlow::PayloadBuilder).to receive(:build_track).and_raise(ArgumentError, 'boom')

        expect(Rails.logger).to receive(:error).with(/message_created failed: ArgumentError: boom/)
        expect(listener.message_created(data: payload)).to be_nil
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when perform_async raises Redis::BaseConnectionError (F6/F7)' do
      it 'tags [enqueue-loss] at error level and does not propagate' do
        stub_const('Redis::BaseConnectionError', Class.new(StandardError)) unless defined?(Redis::BaseConnectionError)
        allow(EvoFlow::PublishEventWorker).to receive(:perform_async)
          .and_raise(Redis::BaseConnectionError, 'redis down')

        expect(Rails.logger).to receive(:error).with(/\[EvoFlow\]\[enqueue-loss\].*Redis::BaseConnectionError/)
        expect { listener.message_created(data: payload) }.not_to raise_error
      end
    end

    describe 'message_id idempotency (AC17)' do
      it 'produces identical messageId for two firings of the same record event' do
        allow(EvoFlow::PayloadBuilder).to receive(:message_id_for).and_call_original

        2.times { listener.message_created(data: payload) }

        jobs = EvoFlow::PublishEventWorker.jobs
        expect(jobs.size).to eq(2)
        expect(jobs[0]['args'][1]['messageId']).to eq(jobs[1]['args'][1]['messageId'])
      end
    end

    # M5: only `incoming`/`outgoing` are tracked; `activity` (system) and
    # `template` (whatsapp template / CSAT broadcast) are intentionally dropped.
    describe 'message_type filter (M5)' do
      %w[activity template].each do |dropped_type|
        context "when message_type is #{dropped_type}" do
          let(:message) do
            instance_double(
              Message, id: 555, conversation: conversation, conversation_id: 100,
                       message_type: dropped_type, content_type: 'text', content: 'x',
                       created_at: created_at, updated_at: updated_at
            )
          end

          it 'does not enqueue' do
            listener.message_created(data: payload)
            expect(EvoFlow::PublishEventWorker.jobs).to be_empty
          end
        end
      end

      it 'tracks outgoing messages' do
        out_message = instance_double(
          Message, id: 556, conversation: conversation, conversation_id: 100,
                   message_type: 'outgoing', content_type: 'text', content: 'ok',
                   created_at: created_at, updated_at: updated_at
        )
        listener.message_created(data: { message: out_message })
        expect(EvoFlow::PublishEventWorker.jobs.size).to eq(1)
      end
    end
  end

  # AC3: message_status_changed → message.delivered / message.read / message.failed.
  describe '#message_status_changed' do
    let(:base_payload) { { message: message, previous_status: 'sent', status: 'delivered', external_error: nil } }

    {
      ['sent', 'delivered'] => 'message.delivered',
      ['delivered', 'read'] => 'message.read',
      ['sent', 'failed'] => 'message.failed',
      ['delivered', 'failed'] => 'message.failed',
      ['read', 'failed'] => 'message.failed'
    }.each do |(prev, curr), expected_event|
      it "maps (#{prev} → #{curr}) to #{expected_event} (AC3)" do
        listener.message_status_changed(
          data: { message: message, previous_status: prev, status: curr, external_error: nil }
        )
        job = EvoFlow::PublishEventWorker.jobs.last
        expect(EvoFlow::PublishEventWorker.jobs.size).to eq(1)
        expect(job['args'][1]['event']).to eq(expected_event)
        expect(job['args'][1]['properties']).to include('previous_status' => prev, 'status' => curr)
      end
    end

    it 'drops unmapped transitions with a warn' do
      expect(Rails.logger).to receive(:warn).with(/unmapped transition pending → delivered/)
      listener.message_status_changed(
        data: { message: message, previous_status: 'pending', status: 'delivered' }
      )
      expect(EvoFlow::PublishEventWorker.jobs).to be_empty
    end

    it 'includes external_error in properties when status=failed' do
      listener.message_status_changed(
        data: { message: message, previous_status: 'sent', status: 'failed', external_error: 'boom' }
      )
      job = EvoFlow::PublishEventWorker.jobs.last
      expect(job['args'][1]['properties']).to include('external_error' => 'boom')
    end

    context 'when ENV is absent' do
      before do
        allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return(nil)
        allow(ENV).to receive(:[]).with('EVO_FLOW_ENABLED').and_return(nil)
      end

      it 'does not enqueue' do
        listener.message_status_changed(data: base_payload)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when called with an EventDispatcher payload' do
      it 'returns early — only Wisper-direct shape is accepted' do
        event = Struct.new(:data).new(base_payload)
        listener.message_status_changed(event)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when inbox is missing' do
      let(:conversation) { instance_double(Conversation, contact_id: 42, inbox: nil) }

      it 'logs a warn and does not enqueue' do
        expect(Rails.logger).to receive(:warn).with(/inbox missing for message 555/)
        listener.message_status_changed(data: base_payload)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    describe 'message_id idempotency' do
      it 'produces identical messageId for two firings of the same transition' do
        allow(EvoFlow::PayloadBuilder).to receive(:message_id_for).and_call_original

        2.times { listener.message_status_changed(data: base_payload) }

        jobs = EvoFlow::PublishEventWorker.jobs
        expect(jobs.size).to eq(2)
        expect(jobs[0]['args'][1]['messageId']).to eq(jobs[1]['args'][1]['messageId'])
      end
    end
  end
end
