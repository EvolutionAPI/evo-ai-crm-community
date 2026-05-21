# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe EvoFlow::PipelineEventsListener do
  let(:listener) { described_class.new }
  let(:created_at) { Time.utc(2026, 5, 20, 10, 0, 0) }
  let(:pipeline) { instance_double(Pipeline, name: 'Sales') }
  let(:pipeline_stage) { instance_double(PipelineStage, name: 'Qualified') }
  let(:conversation) { instance_double(Conversation, contact_id: 77) }
  let(:fixed_digest) { 'fixed-digest' }

  let(:lead_item) do
    instance_double(
      PipelineItem,
      id: 9,
      contact_id: 42,
      conversation_id: nil,
      conversation: nil,
      lead?: true,
      pipeline: pipeline,
      pipeline_id: 1,
      pipeline_stage: pipeline_stage,
      pipeline_stage_id: 2,
      assigned_by_id: 3,
      custom_fields: { 'priority' => 'high' },
      created_at: created_at
    )
  end

  let(:deal_item) do
    instance_double(
      PipelineItem,
      id: 10,
      contact_id: nil,
      conversation_id: 200,
      conversation: conversation,
      lead?: false,
      pipeline: pipeline,
      pipeline_id: 1,
      pipeline_stage: pipeline_stage,
      pipeline_stage_id: 2,
      assigned_by_id: 3,
      custom_fields: {},
      created_at: created_at
    )
  end

  before do
    Sidekiq::Testing.fake!
    EvoFlow::PublishEventWorker.clear
    allow(EvoFlow::PayloadBuilder).to receive(:message_id_for).and_return(fixed_digest)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return('test-key')
  end

  after { EvoFlow::PublishEventWorker.clear }

  describe '#pipeline_item_created' do
    context 'with a lead pipeline item (AC9)' do
      it 'uses pipeline_item.contact_id and emits campaign.triggered with is_lead=true' do
        listener.pipeline_item_created(data: { pipeline_item: lead_item })

        job = EvoFlow::PublishEventWorker.jobs.last
        expect(job['args'][0]).to eq('/events/track')
        sent = job['args'][1]
        expect(sent['event']).to eq('campaign.triggered')
        expect(sent['contactId']).to eq('42')
        expect(sent['properties']).to include('is_lead' => true, 'pipeline_id' => 1, 'pipeline_name' => 'Sales')
      end
    end

    context 'with a deal pipeline item (AC10)' do
      it 'uses conversation.contact_id and emits is_lead=false' do
        listener.pipeline_item_created(data: { pipeline_item: deal_item })

        sent = EvoFlow::PublishEventWorker.jobs.last['args'][1]
        expect(sent['contactId']).to eq('77')
        expect(sent['properties']).to include('is_lead' => false)
      end
    end

    context 'without a resolvable contact (AC11)' do
      let(:orphan_item) do
        instance_double(
          PipelineItem,
          id: 11,
          contact_id: nil,
          conversation_id: nil,
          conversation: nil,
          lead?: false,
          created_at: created_at
        )
      end

      it 'logs a warn and does not enqueue' do
        expect(Rails.logger).to receive(:warn).with(/no resolvable contact_id for pipeline_item 11/)
        listener.pipeline_item_created(data: { pipeline_item: orphan_item })
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when ENV is absent (AC12)' do
      before { allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return(nil) }

      it 'does not enqueue and emits no error log' do
        expect(Rails.logger).not_to receive(:error)
        listener.pipeline_item_created(data: { pipeline_item: lead_item })
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when called with an EventDispatcher payload (AC13)' do
      it 'returns early and does not enqueue' do
        event = Struct.new(:data).new({ pipeline_item: lead_item })
        listener.pipeline_item_created(event)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when pipeline_item is missing (AC14)' do
      it 'logs an error and does not enqueue' do
        expect(Rails.logger).to receive(:error).with(/pipeline_item_created.*pipeline_item is nil/)
        listener.pipeline_item_created(data: {})
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when build_track raises (AC15)' do
      it 'logs the error and returns nil' do
        allow(EvoFlow::PayloadBuilder).to receive(:build_track).and_raise(ArgumentError, 'boom')

        expect(Rails.logger).to receive(:error).with(/pipeline_item_created failed: ArgumentError: boom/)
        expect(listener.pipeline_item_created(data: { pipeline_item: lead_item })).to be_nil
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when perform_async raises Redis::BaseConnectionError (F6/F7)' do
      it 'tags [enqueue-loss] at error level and does not propagate' do
        stub_const('Redis::BaseConnectionError', Class.new(StandardError)) unless defined?(Redis::BaseConnectionError)
        allow(EvoFlow::PublishEventWorker).to receive(:perform_async)
          .and_raise(Redis::BaseConnectionError, 'redis down')

        expect(Rails.logger).to receive(:error).with(/\[EvoFlow\]\[enqueue-loss\].*Redis::BaseConnectionError/)
        expect { listener.pipeline_item_created(data: { pipeline_item: lead_item }) }.not_to raise_error
      end
    end

    describe 'message_id idempotency (AC17)' do
      it 'produces identical messageId for two firings of the same record event' do
        allow(EvoFlow::PayloadBuilder).to receive(:message_id_for).and_call_original

        2.times { listener.pipeline_item_created(data: { pipeline_item: lead_item }) }

        jobs = EvoFlow::PublishEventWorker.jobs
        expect(jobs.size).to eq(2)
        expect(jobs[0]['args'][1]['messageId']).to eq(jobs[1]['args'][1]['messageId'])
      end
    end

    # F11: properties.contact_id should match the resolved root contactId.
    it 'sets properties.contact_id to the resolved root contactId on deals' do
      listener.pipeline_item_created(data: { pipeline_item: deal_item })

      sent = EvoFlow::PublishEventWorker.jobs.last['args'][1]
      expect(sent['properties']['contact_id']).to eq(sent['contactId'].to_i).or eq(sent['contactId'])
    end
  end
end
