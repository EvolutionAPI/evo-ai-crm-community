# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::PipelineItemsController, type: :controller do
  let(:user) { User.create!(email: 'pipeline-items-spec@example.com', name: 'Spec User') }
  let(:pipeline) do
    Pipeline.create!(name: 'Sales Pipeline', pipeline_type: 'sales', created_by: user)
  end
  let!(:stage_one) { PipelineStage.create!(pipeline: pipeline, name: 'Lead', position: 1) }
  let!(:stage_two) { PipelineStage.create!(pipeline: pipeline, name: 'Qualified', position: 2) }
  let(:contact) { Contact.create!(name: 'Jane Doe', email: 'jane@example.com') }
  let!(:pipeline_item) do
    PipelineItem.create!(
      pipeline: pipeline,
      pipeline_stage: stage_one,
      contact: contact,
      assigned_by: user
    )
  end

  before do
    Current.user = user
    Current.service_authenticated = true
    Current.authentication_method = 'service_token'

    allow(controller).to receive(:authenticate_request!).and_return(true)
    allow(controller).to receive(:authorize).and_return(true)
    allow(controller).to receive(:pundit_user).and_return({ user: user, account_user: nil })
  end

  after { Current.reset }

  describe 'PATCH #update' do
    context 'when changing the pipeline stage (EVO-1005)' do
      it 'persists the new pipeline_stage_id' do
        patch :update, params: {
          pipeline_id: pipeline.id,
          id: pipeline_item.id,
          pipeline_stage_id: stage_two.id
        }

        expect(response).to have_http_status(:ok)
        expect(pipeline_item.reload.pipeline_stage_id).to eq(stage_two.id)
      end

      it 'creates a stage_movement audit row for the change' do
        expect do
          patch :update, params: {
            pipeline_id: pipeline.id,
            id: pipeline_item.id,
            pipeline_stage_id: stage_two.id
          }
        end.to change { pipeline_item.stage_movements.count }.by(1)

        movement = pipeline_item.stage_movements.order(:created_at).last
        expect(movement.from_stage_id).to eq(stage_one.id)
        expect(movement.to_stage_id).to eq(stage_two.id)
        expect(movement.movement_type).to eq('manual')
      end

      it 'attaches notes to the new stage_movement when provided' do
        patch :update, params: {
          pipeline_id: pipeline.id,
          id: pipeline_item.id,
          pipeline_stage_id: stage_two.id,
          notes: 'Moved after qualification call'
        }

        expect(response).to have_http_status(:ok)
        expect(pipeline_item.stage_movements.order(:created_at).last.notes)
          .to eq('Moved after qualification call')
      end

      it 'returns the serialized item with the new stage' do
        patch :update, params: {
          pipeline_id: pipeline.id,
          id: pipeline_item.id,
          pipeline_stage_id: stage_two.id
        }

        body = response.parsed_body
        expect(body.dig('data', 'pipeline_stage_id') || body.dig('data', 'stage_id') ||
               body.dig('data', 'pipeline_stage', 'id')).to eq(stage_two.id)
      end

      it 'rejects a stage that belongs to a different pipeline (404)' do
        other_pipeline = Pipeline.create!(name: 'Other', pipeline_type: 'sales', created_by: user)
        foreign_stage = PipelineStage.create!(pipeline: other_pipeline, name: 'Foreign', position: 1)

        patch :update, params: {
          pipeline_id: pipeline.id,
          id: pipeline_item.id,
          pipeline_stage_id: foreign_stage.id
        }

        expect(response).to have_http_status(:not_found)
        expect(pipeline_item.reload.pipeline_stage_id).to eq(stage_one.id)
      end
    end

    context 'when stage is unchanged' do
      it 'does not create a new stage_movement' do
        expect do
          patch :update, params: {
            pipeline_id: pipeline.id,
            id: pipeline_item.id,
            pipeline_stage_id: stage_one.id,
            custom_fields: { currency: 'BRL' }
          }
        end.not_to(change { pipeline_item.stage_movements.count })

        expect(response).to have_http_status(:ok)
      end
    end

    context 'when only custom_fields are provided' do
      it 'updates custom_fields without touching the stage' do
        patch :update, params: {
          pipeline_id: pipeline.id,
          id: pipeline_item.id,
          custom_fields: { currency: 'USD' }
        }

        expect(response).to have_http_status(:ok)
        expect(pipeline_item.reload.custom_fields['currency']).to eq('USD')
        expect(pipeline_item.pipeline_stage_id).to eq(stage_one.id)
      end
    end
  end

  # EVO-1272 [10.14]: endpoint consumed by the evo-flow Journey "Move to
  # Pipeline Stage" node. Resolves the conversation's current placement
  # server-side (same-pipeline / cross-pipeline / assign) so the Journey
  # node output matches the Automation Rules pipeline action (10.B parity).
  describe 'PATCH #move_conversation' do
    let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
    let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

    context 'when the conversation is already active in the target pipeline (same-pipeline, AC1)' do
      before do
        Pipelines::ConversationService.new(pipeline: pipeline, user: user).add_conversation(conversation, stage: stage_one)
      end

      it 'moves the existing item to the target stage' do
        patch :move_conversation, params: {
          pipeline_id: pipeline.id,
          conversation_id: conversation.id,
          pipeline_stage_id: stage_two.id
        }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig('data', 'movement_type')).to eq('same_pipeline')
        item = conversation.pipeline_items.active.find_by(pipeline: pipeline)
        expect(item.pipeline_stage_id).to eq(stage_two.id)
      end
    end

    context 'when the conversation is active in a different pipeline (cross-pipeline, AC2)' do
      let(:other_pipeline) { Pipeline.create!(name: 'Support', pipeline_type: 'sales', created_by: user) }
      let!(:other_stage) { PipelineStage.create!(pipeline: other_pipeline, name: 'Triage', position: 1) }

      before do
        Pipelines::ConversationService.new(pipeline: other_pipeline, user: user).add_conversation(conversation, stage: other_stage)
      end

      it 'relocates the item to the target pipeline/stage and removes it from the previous pipeline' do
        patch :move_conversation, params: {
          pipeline_id: pipeline.id,
          conversation_id: conversation.id,
          pipeline_stage_id: stage_two.id
        }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig('data', 'movement_type')).to eq('cross_pipeline')
        expect(conversation.pipeline_items.active.where(pipeline: other_pipeline)).to be_empty
        moved = conversation.pipeline_items.active.find_by(pipeline: pipeline)
        expect(moved.pipeline_stage_id).to eq(stage_two.id)
      end
    end

    context 'when the conversation is not in any pipeline (auto-assign)' do
      it 'creates a pipeline_item in the target pipeline at the target stage' do
        expect do
          patch :move_conversation, params: {
            pipeline_id: pipeline.id,
            conversation_id: conversation.id,
            pipeline_stage_id: stage_two.id
          }
        end.to change { conversation.pipeline_items.active.count }.from(0).to(1)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig('data', 'movement_type')).to eq('assigned')
        expect(conversation.pipeline_items.active.first.pipeline_stage_id).to eq(stage_two.id)
      end
    end

    context 'when the target stage does not exist (deleted stage, AC3)' do
      before do
        Pipelines::ConversationService.new(pipeline: pipeline, user: user).add_conversation(conversation, stage: stage_one)
      end

      it 'degrades to a logged skip without moving the item' do
        patch :move_conversation, params: {
          pipeline_id: pipeline.id,
          conversation_id: conversation.id,
          pipeline_stage_id: SecureRandom.uuid
        }

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body.dig('data', 'skipped')).to be(true)
        expect(body.dig('data', 'reason')).to eq('stage_not_found')
        expect(conversation.pipeline_items.active.find_by(pipeline: pipeline).pipeline_stage_id).to eq(stage_one.id)
      end
    end
  end
end
