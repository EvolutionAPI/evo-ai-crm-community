# frozen_string_literal: true

require 'rails_helper'

# Creation endpoints that carry no require_permissions map are authorized
# through Pundit instead: the controller invokes the resource policy #create?
# (matching how its sibling update/destroy actions are authorized). These
# policies existed but were never invoked on create, leaving the write open.
# The specs prove create now consults the policy: a denied policy blocks the
# write and never persists, an allowed policy yields 201. A Pundit denial is
# reported as 401 by the app-wide RequestExceptionHandler (the same status the
# sibling update/destroy actions in these controllers return on denial).
RSpec.describe 'Pundit-gated create actions RBAC', type: :request do
  let(:user) { User.create!(name: 'Perm Probe', email: "probe-#{SecureRandom.hex(4)}@example.com") }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
  end

  after { Current.reset }

  describe 'POST /api/v1/scheduled_actions' do
    let(:contact) { Contact.create!(name: "Contact #{SecureRandom.hex(3)}") }

    def create_params
      {
        scheduled_action: {
          action_type: 'send_message',
          scheduled_for: 1.hour.from_now.iso8601,
          contact_id: contact.id,
          payload: { message: 'hi' }
        }
      }
    end

    it 'denies creation when the policy forbids it' do
      allow_any_instance_of(ScheduledActionPolicy).to receive(:create?).and_return(false)

      expect do
        post '/api/v1/scheduled_actions', params: create_params, as: :json
      end.not_to change(ScheduledAction, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'creates when the policy allows it' do
      allow_any_instance_of(ScheduledActionPolicy).to receive(:create?).and_return(true)

      expect do
        post '/api/v1/scheduled_actions', params: create_params, as: :json
      end.to change(ScheduledAction, :count).by(1)

      expect(response).to have_http_status(:created)
    end
  end

  describe 'POST /api/v1/pipelines/:pipeline_id/pipeline_items/:pipeline_item_id/tasks' do
    # EVO-2204 put a pipeline gate ahead of the task policy. `user` would pass it anyway,
    # but it reaches the auth-service — stubbed to keep these specs about PipelineTaskPolicy.
    before { allow_any_instance_of(PipelinePolicy).to receive(:view?).and_return(true) }

    let(:pipeline) { Pipeline.create!(name: 'Sales', pipeline_type: 'sales', created_by: user) }
    let!(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'Lead', position: 1) }
    let(:channel) { Channel::WebWidget.create!(website_url: 'https://pundit.example.com') }
    let(:inbox) { Inbox.create!(name: "Inbox #{SecureRandom.hex(3)}", channel: channel) }
    let(:contact) { Contact.create!(name: "Contact #{SecureRandom.hex(3)}") }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
    let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
    let(:pipeline_item) do
      Pipelines::ConversationService.new(pipeline: pipeline, user: user)
                                    .add_conversation(conversation, stage: stage)
      conversation.pipeline_items.first
    end

    def task_url
      "/api/v1/pipelines/#{pipeline.id}/pipeline_items/#{pipeline_item.id}/tasks"
    end

    def create_params
      { task: { title: 'Follow up', task_type: 'call', priority: 'low' } }
    end

    it 'denies creation when the policy forbids it' do
      allow_any_instance_of(PipelineTaskPolicy).to receive(:create?).and_return(false)

      expect do
        post task_url, params: create_params, as: :json
      end.not_to change(PipelineTask, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'creates when the policy allows it' do
      allow_any_instance_of(PipelineTaskPolicy).to receive(:create?).and_return(true)

      expect do
        post task_url, params: create_params, as: :json
      end.to change(PipelineTask, :count).by(1)

      expect(response).to have_http_status(:created)
    end
  end
end
