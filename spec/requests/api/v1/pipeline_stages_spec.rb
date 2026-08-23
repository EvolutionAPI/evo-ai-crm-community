# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::PipelineStagesController, type: :controller do
  let(:user) { User.create!(email: 'stage-spec@example.com', name: 'Stage Spec') }
  let(:pipeline) do
    Pipeline.create!(name: 'Sales Pipeline', pipeline_type: 'sales', created_by: user)
  end

  before do
    Current.user = user
    Current.service_authenticated = true
    Current.authentication_method = 'service_token'

    allow(controller).to receive(:authenticate_request!).and_return(true)
    allow(controller).to receive(:authorize).and_return(true)
    allow(controller).to receive(:pundit_user).and_return({ user: user, account_user: nil })
  end

  after do
    Current.reset
  end

  describe 'automation_rules on update' do
    let(:rule) do
      {
        'trigger' => 'label_added',
        'trigger_value' => 'lead qualificado',
        'action' => 'apply_label',
        'action_value' => 'em negociacao'
      }
    end

    let!(:stage) do
      pipeline.pipeline_stages.create!(
        name: 'Lead',
        position: 1,
        color: '#60A5FA',
        automation_rules: { 'description' => 'Primeiro contato com o lead', 'rules' => [rule] }
      )
    end

    # as: :json so an empty `rules: []` survives the round trip — form encoding drops it,
    # which is not how the copilot or the frontend call the endpoint.
    def update_stage(automation_rules)
      put :update,
          params: {
            pipeline_id: pipeline.id,
            id: stage.id,
            pipeline_stage: { automation_rules: automation_rules }
          },
          as: :json
    end

    it 'keeps the description when only the rules are sent' do
      new_rule = rule.merge('action_value' => 'proposta enviada')

      update_stage(rules: [new_rule])

      expect(response).to have_http_status(:ok)
      automation_rules = JSON.parse(response.body).dig('data', 'automation_rules')
      expect(automation_rules['description']).to eq('Primeiro contato com o lead')
      expect(automation_rules['rules'].first['action_value']).to eq('proposta enviada')
      expect(stage.reload.automation_rules['description']).to eq('Primeiro contato com o lead')
    end

    it 'keeps the rules when only the description is sent' do
      update_stage(description: 'Lead recem-chegado')

      expect(response).to have_http_status(:ok)
      automation_rules = stage.reload.automation_rules
      expect(automation_rules['description']).to eq('Lead recem-chegado')
      expect(automation_rules['rules']).to eq([rule])
    end

    it 'clears the description when it is sent empty' do
      update_stage(description: '')

      expect(stage.reload.automation_rules['description']).to eq('')
      expect(stage.reload.automation_rules['rules']).to eq([rule])
    end

    it 'clears the rules when an empty list is sent' do
      update_stage(rules: [])

      expect(stage.reload.automation_rules['rules']).to eq([])
      expect(stage.reload.automation_rules['description']).to eq('Primeiro contato com o lead')
    end
  end

  describe 'POST #create' do
    it 'stores the description sent inside automation_rules' do
      post :create,
           params: {
             pipeline_id: pipeline.id,
             pipeline_stage: {
               name: 'Qualified',
               color: '#F59E0B',
               automation_rules: { description: 'Lead com fit confirmado' }
             }
           }

      expect(response).to have_http_status(:created)
      automation_rules = JSON.parse(response.body).dig('data', 'automation_rules')
      expect(automation_rules['description']).to eq('Lead com fit confirmado')
    end
  end
end
