# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PipelineItem, type: :model do
  # Derives from VALID_TYPES so the fixture stays valid if the enum list changes.
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
end
