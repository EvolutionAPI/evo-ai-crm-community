# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::PipelineTasksController, type: :controller do
  let(:user) { User.create!(email: "pt-spec-#{SecureRandom.hex(4)}@example.com", name: 'Spec User') }
  let(:pipeline) { Pipeline.create!(name: 'Sales', pipeline_type: 'sales', created_by: user) }
  let!(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'Lead', position: 1) }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Jane', email: "jane-#{SecureRandom.hex(4)}@example.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  before do
    Current.user = user
    Current.service_authenticated = true
    Current.authentication_method = 'service_token'

    allow(controller).to receive(:authenticate_request!).and_return(true)
    allow(controller).to receive(:authorize).and_return(true)
    allow(controller).to receive(:pundit_user).and_return({ user: user, account_user: nil })
  end

  after { Current.reset }

  describe 'POST #for_conversation' do
    context 'when the conversation has an active pipeline_item' do
      before do
        Pipelines::ConversationService.new(pipeline: pipeline, user: user).add_conversation(conversation, stage: stage)
      end

      it 'creates a task with all provided values (AC1)' do
        assignee = User.create!(email: "assignee-#{SecureRandom.hex(4)}@example.com", name: 'Assignee')

        expect do
          post :for_conversation, params: {
            conversation_id: conversation.id,
            title: 'Follow up with {contact.name}',
            description: 'Call the lead',
            task_type: 'call',
            priority: 'high',
            assigned_to_id: assignee.id,
            due_in: '2.hours'
          }
        end.to change { conversation.pipeline_items.first.tasks.count }.from(0).to(1)

        expect(response).to have_http_status(:created)
        task = conversation.pipeline_items.first.tasks.first
        expect(task.title).to eq('Follow up with {contact.name}')
        expect(task.task_type).to eq('call')
        expect(task.priority).to eq('high')
        expect(task.assigned_to_id).to eq(assignee.id)
        expect(task.due_date).to be_within(1.minute).of(2.hours.from_now)
      end

      it 'creates a task with defaults when only the title is given (AC2)' do
        post :for_conversation, params: { conversation_id: conversation.id, title: 'Minimal task' }

        expect(response).to have_http_status(:created)
        task = conversation.pipeline_items.first.tasks.first
        expect(task.task_type).to eq('call')
        expect(task.priority).to eq('low')
        expect(task.due_date).to be_nil
      end

      it 'falls back to the conversation assignee for created_by when Current.user is absent' do
        agent = User.create!(email: "agent-#{SecureRandom.hex(4)}@example.com", name: 'Agent')
        conversation.update!(assignee: agent)
        Current.user = nil

        post :for_conversation, params: { conversation_id: conversation.id, title: 'Owned task' }

        expect(response).to have_http_status(:created)
        expect(conversation.pipeline_items.first.tasks.first.created_by_id).to eq(agent.id)
      end

      it 'returns a validation error when the title is missing' do
        post :for_conversation, params: { conversation_id: conversation.id, description: 'no title' }

        expect(response).to have_http_status(:unprocessable_entity).or have_http_status(:bad_request)
        expect(conversation.pipeline_items.first.tasks.count).to eq(0)
      end

      it 'creates the task unassigned when the assignee does not exist (invalid assignee)' do
        post :for_conversation, params: {
          conversation_id: conversation.id,
          title: 'Unassignable task',
          assigned_to_id: SecureRandom.uuid
        }

        expect(response).to have_http_status(:created)
        expect(conversation.pipeline_items.first.tasks.first.assigned_to_id).to be_nil
      end
    end

    context 'when the conversation has no active pipeline_item (AC3)' do
      it 'degrades to a logged skip without creating a task' do
        post :for_conversation, params: { conversation_id: conversation.id, title: 'Orphan task' }

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body.dig('data', 'skipped')).to be(true)
        expect(body.dig('data', 'reason')).to eq('no_pipeline_item')
      end
    end

    context 'when the conversation does not exist' do
      it 'returns a not-found error' do
        post :for_conversation, params: { conversation_id: SecureRandom.uuid, title: 'x' }

        expect(response).not_to have_http_status(:created)
      end
    end
  end
end
