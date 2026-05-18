# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PipelineStageAutomationListener do
  let(:listener) { described_class.instance }

  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  EventData = Struct.new(:data) unless defined?(EventData)

  describe '#conversation_updated' do
    let(:event_data) do
      {
        conversation: conversation,
        changed_attributes: { 'label_list' => [[], ['urgent']] }
      }
    end
    let(:event) { EventData.new(event_data) }

    context 'when the event was triggered by stage automation' do
      before { event_data[:performed_by] = :stage_automation }

      it 'skips execution to prevent loops' do
        expect(Pipelines::StageAutomationService).not_to receive(:new)
        listener.conversation_updated(event)
      end
    end

    context 'when no relevant attributes changed' do
      before { event_data[:changed_attributes] = { 'assignee_id' => [nil, user.id] } }

      it 'skips execution' do
        expect(Pipelines::StageAutomationService).not_to receive(:new)
        listener.conversation_updated(event)
      end
    end

    context 'when label_list changed and conversation has pipeline items' do
      let(:pipeline) { Pipeline.create!(name: 'P', pipeline_type: 'custom', created_by: user) }
      let(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'S', position: 1) }
      let!(:_item) { PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation) }

      it 'calls StageAutomationService' do
        service_double = instance_double(Pipelines::StageAutomationService, perform: nil)
        expect(Pipelines::StageAutomationService)
          .to receive(:new).with(conversation, event_data[:changed_attributes]).and_return(service_double)
        listener.conversation_updated(event)
      end
    end

    context 'when conversation has no pipeline items' do
      # Prevent assign_to_default_pipeline from auto-assigning the conversation on creation.
      # Without this, the test DB's default pipeline would create a PipelineItem, making
      # pipeline_items.exists? return true and causing the listener to call the service.
      before { allow(Pipeline).to receive(:default).and_return(Pipeline.none) }

      it 'does not call StageAutomationService' do
        expect(Pipelines::StageAutomationService).not_to receive(:new)
        listener.conversation_updated(event)
      end
    end

    context 'when status changed' do
      before { event_data[:changed_attributes] = { 'status' => ['open', 'resolved'] } }

      let(:pipeline) { Pipeline.create!(name: 'P', pipeline_type: 'custom', created_by: user) }
      let(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'S', position: 1) }
      let!(:_item) { PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation) }

      it 'calls StageAutomationService' do
        service_double = instance_double(Pipelines::StageAutomationService, perform: nil)
        expect(Pipelines::StageAutomationService).to receive(:new).and_return(service_double)
        listener.conversation_updated(event)
      end
    end
  end
end
