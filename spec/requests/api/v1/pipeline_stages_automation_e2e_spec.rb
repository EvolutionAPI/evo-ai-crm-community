# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# End to end over the stage automation surface: real routing, parsing, auth gate and database.
# The controller specs next door drive the action directly, so they never see the two things
# that actually broke here — how a payload parses off the wire, and what survives more than
# one request in a row.
RSpec.describe 'Pipeline stage automation, end to end', type: :request do
  let(:auth_url) { 'http://auth.test' }
  let(:token) { 'e2e-bearer-token' }

  let!(:owner) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: "Funnel #{SecureRandom.hex(4)}", pipeline_type: 'sales', created_by: owner) }

  let(:label_rule) do
    { 'trigger' => 'label_added', 'trigger_value' => 'Lead Qualificado',
      'action' => 'apply_label', 'action_value' => 'quente' }
  end
  let(:inactivity_rule) do
    { 'trigger' => 'inactivity', 'trigger_value' => { 'minutes' => 30, 'base' => 'stage_stagnation' },
      'action' => 'send_direct_message', 'action_value' => 'segue o combinado?' }
  end

  around do |example|
    previous = ENV.fetch('EVO_AUTH_SERVICE_URL', nil)
    ENV['EVO_AUTH_SERVICE_URL'] = auth_url
    Rails.cache.clear
    Current.reset
    example.run
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = previous
  end

  before { grant_stage_permissions }

  # Every request re-validates the bearer against evo-auth, which is what makes a multi-step
  # flow (create, then update, then read) survive the Current reset between requests.
  def grant_stage_permissions
    stub_request(:post, "#{auth_url}/api/v1/auth/validate")
      .to_return(status: 200,
                 body: { success: true,
                         data: { user: { id: owner.id, email: owner.email,
                                         role: { id: 1, key: 'administrator', name: 'Admin' } } } }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
    stub_request(:post, %r{#{auth_url}/api/v1/users/#{owner.id}/check_permission})
      .to_return(status: 200, body: { success: true, data: { has_permission: true } }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  def headers = { 'Authorization' => "Bearer #{token}" }

  def stages_path = "/api/v1/pipelines/#{pipeline.id}/pipeline_stages"

  def create_stage(**payload)
    post stages_path, params: { pipeline_stage: payload }, headers: headers, as: :json
  end

  def update_stage(stage, **payload)
    put "#{stages_path}/#{stage.id}", params: { pipeline_stage: payload }, headers: headers, as: :json
  end

  # Same writes, no `as: :json` — the request goes out form-encoded, which is the parsing
  # path a controller spec never exercises.
  def create_stage_form(**payload)
    post stages_path, params: { pipeline_stage: payload }, headers: headers
  end

  def update_stage_form(stage, **payload)
    put "#{stages_path}/#{stage.id}", params: { pipeline_stage: payload }, headers: headers
  end

  def automation_rules = response.parsed_body.dig('data', 'automation_rules')
  def details = response.parsed_body.dig('error', 'details')

  describe 'the flow an operator performs building a funnel' do
    it 'carries the description and the rules across a whole edit session' do
      create_stage(name: 'Lead', color: '#60A5FA',
                   automation_rules: { description: 'primeiro contato', rules: [label_rule] })
      expect(response).to have_http_status(:created)
      stage = PipelineStage.find(response.parsed_body.dig('data', 'id'))

      # The form sends only what its section owns, so a rules-only write must not take the
      # description with it — and the mirror case must not take the rules.
      update_stage(stage, automation_rules: { rules: [label_rule.merge('action_value' => 'frio')] })
      expect(response).to have_http_status(:ok)
      expect(automation_rules['description']).to eq('primeiro contato')

      update_stage(stage, automation_rules: { description: 'primeiro contato, revisado' })
      expect(response).to have_http_status(:ok)
      expect(automation_rules['rules'].first['action_value']).to eq('frio')

      get "/api/v1/pipelines/#{pipeline.id}/pipeline_stages/#{stage.id}", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(automation_rules).to include('description' => 'primeiro contato, revisado')
      expect(automation_rules['rules'].first).to include('trigger' => 'label_added')

      # And the same pair comes back on the collection the board reads.
      get "/api/v1/pipelines/#{pipeline.id}/pipeline_stages", headers: headers, as: :json
      listed = response.parsed_body['data'].find { |s| s['id'] == stage.id }
      expect(listed['automation_rules']).to include('description' => 'primeiro contato, revisado')
    end

    it 'clears each key only when it is sent empty' do
      create_stage(name: 'Lead', automation_rules: { description: 'some daqui', rules: [label_rule] })
      stage = PipelineStage.find(response.parsed_body.dig('data', 'id'))

      update_stage(stage, automation_rules: { description: '' })
      expect(automation_rules['description']).to eq('')
      expect(automation_rules['rules']).to be_present

      update_stage(stage, automation_rules: { rules: [] })
      expect(automation_rules['rules']).to eq([])
    end
  end

  describe 'the flow the copilot performs writing an inactivity follow-up' do
    it 'stores the clock it was asked for rather than the default' do
      create_stage(name: 'Follow-up', automation_rules: { rules: [inactivity_rule] })
      expect(response).to have_http_status(:created)
      expect(automation_rules['rules'].first['trigger_value']).to eq(
        'minutes' => 30, 'base' => 'stage_stagnation'
      )
    end

    it 'falls back to no_customer_reply only when no base is sent' do
      create_stage(name: 'Follow-up',
                   automation_rules: { rules: [inactivity_rule.merge('trigger_value' => { 'minutes' => 45 })] })
      expect(automation_rules['rules'].first['trigger_value']).to eq(
        'minutes' => 45, 'base' => 'no_customer_reply'
      )
    end

    # Each of these used to be accepted and quietly reshaped into a rule that fires on the
    # next sweep instead of after the delay that was asked for.
    {
      'a base outside the enum' => { 'minutes' => 30, 'base' => 'last_activity' },
      'minutes that cannot be read' => { 'minutes' => 'trinta', 'base' => 'stage_stagnation' },
      'no minutes at all' => { 'base' => 'stage_stagnation' },
      'a trigger_value that is not an object' => '30'
    }.each do |label, trigger_value|
      it "refuses #{label} and creates nothing" do
        expect { create_stage(name: 'Ruim', automation_rules: { rules: [inactivity_rule.merge('trigger_value' => trigger_value)] }) }
          .not_to change(PipelineStage, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(details.join(' ')).to include('trigger_value')
      end
    end
  end

  describe 'the refusals that used to be silent' do
    let!(:stage) do
      pipeline.pipeline_stages.create!(name: 'Lead', position: 1, color: '#60A5FA',
                                       automation_rules: { 'description' => 'intacta', 'rules' => [label_rule] })
    end

    def expect_stage_untouched
      expect(stage.reload.automation_rules['description']).to eq('intacta')
      expect(stage.automation_rules['rules'].first['trigger']).to eq('label_added')
      expect(stage.stage_type).to eq('active')
    end

    it 'names the trigger it refused' do
      update_stage(stage, automation_rules: { rules: [label_rule.merge('trigger' => 'stage_entered')] })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(details).to include(a_string_including('trigger "stage_entered" is not supported'))
      expect_stage_untouched
    end

    it 'names the action it refused' do
      update_stage(stage, automation_rules: { rules: [label_rule.merge('action' => 'send_pigeon')] })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(details).to include(a_string_including('action "send_pigeon" is not supported'))
      expect_stage_untouched
    end

    # This one was the worst of the set: the string wiped the whole jsonb object, description
    # and rules together, and answered 200 doing it.
    it 'refuses automation_rules sent as a JSON string without wiping what is stored' do
      update_stage(stage, automation_rules: '{"rules":[]}')
      expect(response).to have_http_status(:unprocessable_entity)
      expect(details).to include('automation_rules must be an object')
      expect_stage_untouched
    end

    it 'refuses a rules list that is not an array' do
      update_stage(stage, automation_rules: { rules: { '0' => label_rule } })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(details).to include('automation_rules.rules must be an array')
      expect_stage_untouched
    end

    it 'refuses an unknown stage_type instead of raising out of the enum' do
      update_stage(stage, stage_type: 'em_negociacao')
      expect(response).to have_http_status(:unprocessable_entity)
      expect(details).to include(a_string_including('stage_type "em_negociacao" is not supported'))
      expect_stage_untouched
    end

    it 'refuses a blank stage_type instead of nulling the column' do
      update_stage(stage, stage_type: '')
      expect(response).to have_http_status(:unprocessable_entity)
      expect(details).to include(a_string_including('stage_type "" is not supported'))
      expect_stage_untouched
    end

    it 'refuses an overlong description instead of trimming it' do
      update_stage(stage, automation_rules: { description: 'a' * 501 })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(details).to include(a_string_including('at most 500 characters'))
      expect_stage_untouched
    end
  end

  # The bug that started all of this came off the wire, not out of the action: a list encoded
  # one way parses as an array and another way as an object keyed by index. A controller spec
  # cannot tell the two apart because it never parses anything.
  describe 'the same writes sent form-encoded' do
    it 'stores a rule and preserves the description exactly as the JSON path does' do
      create_stage_form(name: 'Lead', automation_rules: { description: 'via formulario', rules: [label_rule] })
      expect(response).to have_http_status(:created)
      stage = PipelineStage.find(response.parsed_body.dig('data', 'id'))
      expect(stage.automation_rules['rules'].first).to include('trigger' => 'label_added')

      update_stage_form(stage, automation_rules: { rules: [label_rule.merge('action_value' => 'morno')] })
      expect(response).to have_http_status(:ok)
      expect(automation_rules['description']).to eq('via formulario')
      expect(automation_rules['rules'].first['action_value']).to eq('morno')
    end

    it 'refuses an invalid trigger the same way' do
      stage = pipeline.pipeline_stages.create!(name: 'Lead', position: 1)
      update_stage_form(stage, automation_rules: { rules: [label_rule.merge('trigger' => 'stage_entered')] })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(details).to include(a_string_including('trigger "stage_entered" is not supported'))
    end

    # Raw body on purpose: Rails' form encoder flattens a nested list, so only the wire itself
    # produces the `[['label_added']]` the guard used to hand to to_h and raise on.
    it 'refuses a rule that parses as a list rather than raising a 500' do
      stage = pipeline.pipeline_stages.create!(name: 'Lead', position: 1)
      put "#{stages_path}/#{stage.id}",
          params: 'pipeline_stage[automation_rules][rules][][]=label_added',
          headers: headers.merge('CONTENT_TYPE' => 'application/x-www-form-urlencoded')
      expect(response).to have_http_status(:unprocessable_entity)
      expect(details).to include('automation_rules.rules[0] must be an object')
    end
  end
end
