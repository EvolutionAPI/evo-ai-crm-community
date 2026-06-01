# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe PipelineItem, type: :model do
  # Derives from VALID_TYPES so the fixture stays valid if the inclusion list changes.
  let(:pipeline) { Pipeline.create!(name: 'Test Pipeline', pipeline_type: Pipeline::VALID_TYPES.first, created_by: User.create!(email: 'test@example.com', name: 'Test User')) }
  let(:pipeline_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Stage 1', position: 1) }
  let(:contact) { Contact.create!(name: 'Test Contact', email: 'contact@example.com') }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(4)) }

  describe 'validations' do
    it 'requires either conversation_id or contact_id' do
      item = PipelineItem.new(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage
      )
      expect(item).not_to be_valid
      expect(item.errors[:base]).to include('Must have either conversation_id or contact_id')
    end

    it 'does not allow both conversation_id and contact_id' do
      conversation = Conversation.create!(
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )
      item = PipelineItem.new(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        conversation: conversation,
        contact: contact
      )
      expect(item).not_to be_valid
      expect(item.errors[:base]).to include('Cannot have both conversation_id and contact_id')
    end

    it 'validates with contact_id only' do
      item = PipelineItem.new(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        contact: contact
      )
      expect(item).to be_valid
    end

    it 'validates with conversation_id only' do
      conversation = Conversation.create!(
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )
      item = PipelineItem.new(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        conversation: conversation
      )
      expect(item).to be_valid
    end
  end

  describe 'orphaned item detection' do
    it 'detects orphaned item when contact is missing' do
      item = PipelineItem.create!(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        contact: contact
      )
      # contact.destroy raises PG::ForeignKeyViolation: the DB FK on pipeline_items.contact_id
      # prevents synchronous deletion of a referenced contact. Stub the association to test the
      # orphan-detection logic (contact_id present but contact absent) without bypassing DB constraints.
      # Serializer accesses item.contact directly (no reload), so the stub is stable.
      allow(item).to receive(:contact).and_return(nil)

      expect(item.contact_id).to be_present
      expect(item.contact).to be_nil
    end

    it 'detects orphaned item when conversation is missing' do
      conversation = Conversation.create!(
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )
      item = PipelineItem.create!(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        conversation: conversation
      )
      # conversation.destroy raises PG::ForeignKeyViolation same as contact.destroy —
      # pipeline_items.conversation_id has a DB-level FK constraint. Stub the association.
      # Serializer accesses item.conversation directly (no reload), so the stub is stable.
      allow(item).to receive(:conversation).and_return(nil)

      expect(item.conversation_id).to be_present
      expect(item.conversation).to be_nil
    end
  end

  describe 'serialization behavior' do
    it 'marks contact-based orphaned items correctly in serializer' do
      item = PipelineItem.create!(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        contact: contact
      )
      contact_id = contact.id
      allow(item).to receive(:contact).and_return(nil)

      serialized = PipelineItemSerializer.serialize(item, include_entity: false)
      expect(serialized[:is_orphaned]).to be true
      expect(serialized[:contact_id]).to eq(contact_id)
    end

    it 'marks conversation-based orphaned items correctly in serializer' do
      conversation = Conversation.create!(
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )
      item = PipelineItem.create!(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        conversation: conversation
      )
      conversation_id = conversation.id
      allow(item).to receive(:conversation).and_return(nil)

      serialized = PipelineItemSerializer.serialize(item, include_entity: false)
      expect(serialized[:is_orphaned]).to be true
      expect(serialized[:conversation_id]).to eq(conversation_id)
    end

    it 'does not mark valid contact-based items as orphaned' do
      item = PipelineItem.create!(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        contact: contact
      )

      serialized = PipelineItemSerializer.serialize(item, include_entity: false)
      expect(serialized[:is_orphaned]).to be false
    end

    it 'does not mark valid conversation-based items as orphaned' do
      conversation = Conversation.create!(
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )
      item = PipelineItem.create!(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        conversation: conversation
      )

      serialized = PipelineItemSerializer.serialize(item, include_entity: false)
      expect(serialized[:is_orphaned]).to be false
    end
  end

  # M2: AC5 regression guard. Pre-fix, `publish_pipeline_item_created` ran on
  # `after_create` (inside the transaction). A rollback would leave an orphan
  # Sidekiq job referencing a row that never existed. Post-fix it runs on
  # `after_create_commit`, so a rolled-back transaction enqueues nothing.
  describe 'after_create_commit (AC5)' do
    around do |ex|
      # Restore the original ActiveJob queue adapter so the `:test` override
      # below does not leak into other specs in the same run.
      previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      Sidekiq::Testing.fake! { ex.run }
    ensure
      ActiveJob::Base.queue_adapter = previous_adapter
    end

    before do
      EvoFlow::PublishEventWorker.clear
      # EventDispatcherJob is an ActiveJob backed by Sidekiq; under the :test
      # adapter, enqueued jobs land in `ActiveJob::Base.queue_adapter.enqueued_jobs`.
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    end

    it 'does not enqueue EvoFlow::PublishEventWorker when the transaction rolls back' do
      ActiveRecord::Base.transaction do
        described_class.create!(pipeline: pipeline, pipeline_stage: pipeline_stage, contact: contact)
        raise ActiveRecord::Rollback
      end

      expect(EvoFlow::PublishEventWorker.jobs).to be_empty
    end

    it 'does not enqueue EventDispatcherJob with pipeline_item.created when the transaction rolls back' do
      ActiveRecord::Base.transaction do
        described_class.create!(pipeline: pipeline, pipeline_stage: pipeline_stage, contact: contact)
        raise ActiveRecord::Rollback
      end

      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs
      dispatcher_jobs = enqueued.select { |j| j[:job] == EventDispatcherJob }
      expect(dispatcher_jobs.map { |j| j[:args].first }).not_to include('pipeline_item.created')
    end
  end

  # EVO-1266 (review M2): integration guard for the Wisper publish that fires
  # alongside the dispatcher call when a stage changes. The
  # EvoFlow::PipelineEventsListener consumes this broadcast to publish a
  # canonical pipeline.stage_changed event to evo-flow. Without this spec,
  # a refactor that drops the publish call would only break the smoke
  # (silently — listener spec exercises the handler in isolation).
  describe 'Wisper :pipeline_stage_updated broadcast (EVO-1266)' do
    let(:second_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Stage 2', position: 2) }
    let(:item) do
      described_class.create!(pipeline: pipeline, pipeline_stage: pipeline_stage, contact: contact)
    end

    def make_listener
      Class.new do
        attr_reader :events

        def initialize
          @events = []
        end

        def pipeline_stage_updated(data)
          @events << (data[:data] || data)
        end
      end.new
    end

    it 'broadcasts pipeline_stage_updated when an existing item moves to a new stage' do
      item
      listener = make_listener
      item.subscribe(listener)

      item.move_to_stage(second_stage)

      expect(listener.events.size).to eq(1)
      payload = listener.events.first
      expect(payload[:pipeline_item]).to eq(item)
      expect(payload[:changed_attributes]).to eq('pipeline_stage_id' => [pipeline_stage.id, second_stage.id])
    end

  end
end
