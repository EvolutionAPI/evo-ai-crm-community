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
end
