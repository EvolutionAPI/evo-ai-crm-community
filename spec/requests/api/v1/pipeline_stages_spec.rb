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
    # Current is reset by the executor between requests, so the service-token grant in
    # check_permission! does not survive an example that issues more than one request.
    allow(controller).to receive(:check_permission!).and_return(true)
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

    # Omitting a key and sending it empty must mean different things: the copilot updates
    # one key at a time and expects the other to survive, the UI sends the empty value to
    # clear. A client that clears BY OMISSION cannot be served by both at once.
    it 'leaves an omitted key untouched rather than clearing it' do
      update_stage(rules: [rule])

      expect(stage.reload.automation_rules['description']).to eq('Primeiro contato com o lead')

      update_stage(description: 'Outra descricao')

      expect(stage.reload.automation_rules['rules']).to eq([rule])
    end
  end

  describe 'reading the stage back' do
    let(:rule) do
      {
        'trigger' => 'label_added',
        'trigger_value' => 'lead qualificado',
        'action' => 'move_to_stage',
        'action_value' => 'stage-uuid'
      }
    end

    it 'returns description and rules together on show and index' do
      post :create,
           params: {
             pipeline_id: pipeline.id,
             pipeline_stage: {
               name: 'Lead',
               color: '#60A5FA',
               automation_rules: { description: 'Primeiro contato', rules: [rule] }
             }
           },
           as: :json
      expect(response).to have_http_status(:created)
      stage_id = JSON.parse(response.body).dig('data', 'id')

      put :update,
          params: {
            pipeline_id: pipeline.id,
            id: stage_id,
            pipeline_stage: { automation_rules: { rules: [rule.merge('action_value' => 'outro-stage')] } }
          },
          as: :json
      expect(response).to have_http_status(:ok)

      get :show, params: { pipeline_id: pipeline.id, id: stage_id }

      expect(response).to have_http_status(:ok)
      shown = JSON.parse(response.body).dig('data', 'automation_rules')
      expect(shown['description']).to eq('Primeiro contato')
      expect(shown['rules'].first['action_value']).to eq('outro-stage')

      get :index, params: { pipeline_id: pipeline.id }

      expect(response).to have_http_status(:ok)
      listed = JSON.parse(response.body)['data'].find { |s| s['id'] == stage_id }
      expect(listed['automation_rules']['description']).to eq('Primeiro contato')
      expect(listed['automation_rules']['rules'].first['action_value']).to eq('outro-stage')
    end
  end

  describe 'rejected payloads' do
    let!(:stage) do
      pipeline.pipeline_stages.create!(name: 'Lead', position: 1, color: '#60A5FA')
    end

    it 'rejects an unknown stage_type instead of blowing up' do
      put :update,
          params: {
            pipeline_id: pipeline.id,
            id: stage.id,
            pipeline_stage: { stage_type: 'em_negociacao' }
          },
          as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to be_present
      expect(stage.reload.stage_type).to eq('active')
    end

    it 'rejects a rule with an unknown trigger instead of dropping it' do
      put :update,
          params: {
            pipeline_id: pipeline.id,
            id: stage.id,
            pipeline_stage: {
              automation_rules: {
                rules: [{ 'trigger' => 'stage_entered', 'action' => 'apply_label', 'action_value' => 'x' }]
              }
            }
          },
          as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).dig('error', 'details')).to include(
        a_string_including('trigger "stage_entered" is not supported')
      )
      expect(stage.reload.automation_rules['rules']).to be_nil
    end

    it 'rejects a rule with an unknown action instead of dropping it' do
      put :update,
          params: {
            pipeline_id: pipeline.id,
            id: stage.id,
            pipeline_stage: {
              automation_rules: {
                rules: [{ 'trigger' => 'label_added', 'action' => 'send_pigeon', 'action_value' => 'x' }]
              }
            }
          },
          as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).dig('error', 'details')).to include(
        a_string_including('action "send_pigeon" is not supported')
      )
      expect(stage.reload.automation_rules['rules']).to be_nil
    end

    it 'rejects automation_rules that is not an object' do
      put :update,
          params: {
            pipeline_id: pipeline.id,
            id: stage.id,
            pipeline_stage: { automation_rules: 'nao sou um objeto' }
          },
          as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).dig('error', 'details')).to include(
        'automation_rules must be an object'
      )
    end

    # A caller that guesses the shape sends `rules` as an object keyed by index. Walking it
    # as a list of pairs raises TypeError, which the global rescue turns into a 500 — the
    # very answer this guard exists to replace.
    it 'rejects rules sent as an object instead of raising' do
      put :update,
          params: {
            pipeline_id: pipeline.id,
            id: stage.id,
            pipeline_stage: {
              automation_rules: {
                rules: { '0' => { 'trigger' => 'label_added', 'action' => 'apply_label', 'action_value' => 'x' } }
              }
            }
          },
          as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).dig('error', 'details')).to include(
        'automation_rules.rules must be an array'
      )
    end

    it 'rejects automation_rules sent as a list' do
      put :update,
          params: {
            pipeline_id: pipeline.id,
            id: stage.id,
            pipeline_stage: { automation_rules: [{ 'description' => 'x' }] }
          },
          as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).dig('error', 'details')).to include(
        'automation_rules must be an object'
      )
    end

    it 'rejects an inactivity base outside the enum instead of silently defaulting it' do
      put :update,
          params: {
            pipeline_id: pipeline.id,
            id: stage.id,
            pipeline_stage: {
              automation_rules: {
                rules: [{
                  'trigger' => 'inactivity',
                  'trigger_value' => { 'minutes' => 30, 'base' => 'last_activity' },
                  'action' => 'apply_label',
                  'action_value' => 'frio'
                }]
              }
            }
          },
          as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).dig('error', 'details')).to include(
        a_string_including('trigger_value.base "last_activity" is not supported')
      )
      expect(stage.reload.automation_rules['rules']).to be_nil
    end

    it 'rejects inactivity minutes that would collapse to zero and fire at once' do
      put :update,
          params: {
            pipeline_id: pipeline.id,
            id: stage.id,
            pipeline_stage: {
              automation_rules: {
                rules: [{
                  'trigger' => 'inactivity',
                  'trigger_value' => { 'minutes' => 'trinta', 'base' => 'stage_stagnation' },
                  'action' => 'apply_label',
                  'action_value' => 'frio'
                }]
              }
            }
          },
          as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).dig('error', 'details')).to include(
        a_string_including('trigger_value.minutes "trinta" is not a positive whole number')
      )
      expect(stage.reload.automation_rules['rules']).to be_nil
    end

    it 'rejects an inactivity rule with no minutes at all' do
      put :update,
          params: {
            pipeline_id: pipeline.id,
            id: stage.id,
            pipeline_stage: {
              automation_rules: {
                rules: [{
                  'trigger' => 'inactivity',
                  'trigger_value' => { 'base' => 'stage_stagnation' },
                  'action' => 'apply_label',
                  'action_value' => 'frio'
                }]
              }
            }
          },
          as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).dig('error', 'details')).to include(
        'automation_rules.rules[0].trigger_value.minutes is required for the inactivity trigger'
      )
    end

    it 'stores an inactivity rule whose base and minutes are both valid' do
      put :update,
          params: {
            pipeline_id: pipeline.id,
            id: stage.id,
            pipeline_stage: {
              automation_rules: {
                rules: [{
                  'trigger' => 'inactivity',
                  'trigger_value' => { 'minutes' => '30', 'base' => 'stage_stagnation' },
                  'action' => 'apply_label',
                  'action_value' => 'frio'
                }]
              }
            }
          },
          as: :json

      expect(response).to have_http_status(:ok)
      expect(stage.reload.automation_rules['rules'].first['trigger_value']).to eq(
        'minutes' => 30, 'base' => 'stage_stagnation'
      )
    end

    it 'rejects a description longer than the stored limit instead of truncating it' do
      put :update,
          params: {
            pipeline_id: pipeline.id,
            id: stage.id,
            pipeline_stage: { automation_rules: { description: 'a' * 501 } }
          },
          as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(stage.reload.automation_rules['description']).to be_nil
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
