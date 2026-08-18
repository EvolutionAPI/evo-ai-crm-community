# frozen_string_literal: true

require 'rails_helper'

# EVO-2203: a running journey reaches pipelines through these endpoints. Neither checked
# is_active, so it kept adding and moving conversations inside an archived pipeline. Both
# now refuse with PIPELINE_ARCHIVED so evo-flow can surface a visible failure.
RSpec.describe 'Pipeline item writes on an archived pipeline', type: :request do
  let(:user) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: "Sales #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let!(:stage) { pipeline.pipeline_stages.create!(name: 'New', position: 1) }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Lead', email: "lead-#{SecureRandom.hex(4)}@example.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    # Card writes now authorize against #update_items? (CRM-178); keep #update?
    # and #view? stubbed too so this spec stays focused on the archived-guard, not
    # on the permission split.
    allow_any_instance_of(PipelinePolicy).to receive(:view?).and_return(true)
    allow_any_instance_of(PipelinePolicy).to receive(:update?).and_return(true)
    allow_any_instance_of(PipelinePolicy).to receive(:update_items?).and_return(true)
  end

  after { Current.reset }

  def json_response
    response.parsed_body
  end

  describe 'POST /pipeline_items' do
    it 'refuses to add a conversation to an archived pipeline' do
      pipeline.update!(is_active: false)

      expect do
        post "/api/v1/pipelines/#{pipeline.id}/pipeline_items",
             params: { type: 'conversation', item_id: conversation.id, pipeline_stage_id: stage.id }, as: :json
      end.not_to change(PipelineItem, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response['error']['code']).to eq('PIPELINE_ARCHIVED')
      # evo-flow shows this message verbatim on the journey run, so it is contract.
      expect(json_response['error']['message']).to eq('Pipeline is archived and cannot receive conversations')
    end

    it 'adds the conversation while the pipeline is active' do
      expect do
        post "/api/v1/pipelines/#{pipeline.id}/pipeline_items",
             params: { type: 'conversation', item_id: conversation.id, pipeline_stage_id: stage.id }, as: :json
      end.to change(PipelineItem, :count).by(1)

      expect(response).to have_http_status(:success)
    end
  end

  describe 'PATCH /pipeline_items/move_conversation' do
    let(:other) { Pipeline.create!(name: "Other #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
    let!(:other_stage) { other.pipeline_stages.create!(name: 'Src', position: 1) }

    before { PipelineItem.create!(pipeline: other, pipeline_stage: other_stage, conversation: conversation) }

    it 'refuses to move a conversation into an archived pipeline' do
      pipeline.update!(is_active: false)

      patch "/api/v1/pipelines/#{pipeline.id}/pipeline_items/move_conversation",
            params: { conversation_id: conversation.id, pipeline_stage_id: stage.id }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response['error']['code']).to eq('PIPELINE_ARCHIVED')
      expect(json_response['error']['message']).to eq('Pipeline is archived and cannot receive conversations')
      expect(conversation.pipeline_items.reload.map(&:pipeline_id)).not_to include(pipeline.id)
    end

    it 'moves the conversation while the destination is active' do
      patch "/api/v1/pipelines/#{pipeline.id}/pipeline_items/move_conversation",
            params: { conversation_id: conversation.id, pipeline_stage_id: stage.id }, as: :json

      expect(response).to have_http_status(:success)
    end
  end
end
