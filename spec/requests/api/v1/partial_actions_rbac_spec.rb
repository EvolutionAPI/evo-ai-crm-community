# frozen_string_literal: true

require 'rails_helper'

# Controllers that already carried require_permissions left write actions out
# of the map (unmapped action = fully open). Every routed action must appear
# in its controller's permission map; the contract block asserts the map
# entries exist (require_permissions defines a check_<action>_permission!
# method per mapped action), and the behavioral block exercises 403/200
# through the full request stack for representative actions.
RSpec.describe 'Partially mapped write actions RBAC', type: :request do
  let(:user) { User.create!(name: 'Perm Probe', email: "probe-#{SecureRandom.hex(4)}@example.com") }

  let(:channel) { Channel::WebWidget.create!(website_url: 'https://partial.example.com') }
  let(:inbox) { Inbox.create!(name: "Inbox #{SecureRandom.hex(3)}", channel: channel) }
  let(:contact) { Contact.create!(name: 'Spec Contact') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
      # Inbox visibility is not under test here; grant read_all so the probe
      # reaches the permission gate instead of being scoped out of the fixture.
      Current.evo_can_read_all_inboxes = true
    end
  end

  after { Current.reset }

  def grant_permissions(*granted)
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_service, _user_id, permission|
      granted.include?(permission)
    end
  end

  describe 'permission map contract' do
    {
      'Api::V1::ConversationsController' =>
        %i[mute unmute update_last_seen unread toggle_typing_status meta search filter attachments],
      'Api::V1::Conversations::MessagesController' => %i[index create update destroy retry],
      'Api::V1::Conversations::ParticipantsController' => %i[show create update destroy],
      'Api::V1::Conversations::DraftMessagesController' => %i[show update destroy],
      'Api::V1::Conversations::AssignmentsController' => %i[create],
      'Api::V1::Conversations::LabelsController' => %i[index create],
      'Api::V1::PipelineStagesController' => %i[move_up move_down reorder bulk_move_conversations],
      'Api::V1::Oauth::ApplicationsController' => %i[regenerate_secret],
      'Api::V1::Instagram::AuthorizationsController' => %i[callback]
    }.each do |controller_name, actions|
      actions.each do |action|
        it "#{controller_name} maps ##{action}" do
          controller = controller_name.constantize
          expect(controller.instance_methods).to include(:"check_#{action}_permission!")
        end
      end
    end
  end

  describe 'POST /api/v1/conversations/:id/mute' do
    it 'denies a user without conversations.mute' do
      grant_permissions('conversations.read', 'conversations.update')

      post "/api/v1/conversations/#{conversation.display_id}/mute", as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'mutes for a holder of conversations.mute' do
      grant_permissions('conversations.read', 'conversations.mute')

      post "/api/v1/conversations/#{conversation.display_id}/mute", as: :json

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'conversation sub-resources demand write-level permission' do
    it 'denies message creation with only conversations.read' do
      grant_permissions('conversations.read')

      post "/api/v1/conversations/#{conversation.display_id}/messages",
           params: { content: 'hello' }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(conversation.reload.messages.count).to eq(0)
    end

    it 'denies assignment with only conversations.read' do
      grant_permissions('conversations.read')

      post "/api/v1/conversations/#{conversation.display_id}/assignments",
           params: { assignee_id: user.id }, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'tags labels for a holder of conversations.update' do
      grant_permissions('conversations.read', 'conversations.update')

      post "/api/v1/conversations/#{conversation.display_id}/labels",
           params: { labels: ['vip'] }, as: :json

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['payload']).to eq(['vip'])
    end
  end

  describe 'pipeline stage ordering actions' do
    it 'denies reorder without pipeline_stages.write' do
      grant_permissions('pipeline_stages.read')

      patch '/api/v1/pipelines/0/pipeline_stages/reorder', params: { stage_ids: [] }, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'POST /api/v1/conversations/:id/transcript' do
    it 'denies a holder of only conversations.read' do
      grant_permissions('conversations.read')

      post "/api/v1/conversations/#{conversation.display_id}/transcript",
           params: { email: 'agent@example.com' }, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'schedules the transcript for a holder of conversations.transcript' do
      grant_permissions('conversations.read', 'conversations.transcript')

      post "/api/v1/conversations/#{conversation.display_id}/transcript",
           params: { email: 'agent@example.com' }, as: :json

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /api/v1/oauth/applications/:id/regenerate_secret' do
    let(:application) do
      OauthApplication.create!(name: "App #{SecureRandom.hex(3)}", redirect_uri: 'https://oauth.example.com/cb')
    end

    it 'denies a holder of only oauth_applications.update (dedicated key required)' do
      grant_permissions('oauth_applications.read', 'oauth_applications.update')

      post "/api/v1/oauth/applications/#{application.uid}/regenerate_secret", as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'regenerates for a holder of oauth_applications.regenerate_secret' do
      grant_permissions('oauth_applications.read', 'oauth_applications.regenerate_secret')
      previous_secret = application.secret

      post "/api/v1/oauth/applications/#{application.uid}/regenerate_secret", as: :json

      expect(response).to have_http_status(:ok)
      expect(application.reload.secret).not_to eq(previous_secret)
    end
  end
end
