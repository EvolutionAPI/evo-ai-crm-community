# frozen_string_literal: true

require 'rails_helper'

# EVO-2200: archiving a pipeline was a blind action. This endpoint answers what would keep
# running against it, so the confirmation dialog can name the capture forms that feed it.
RSpec.describe 'Pipeline dependents', type: :request do
  let(:user) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: "Sales #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let!(:stage) { pipeline.pipeline_stages.create!(name: 'New', position: 1) }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?).and_return(true)
    # EVO-2204: dependents now authorizes the pipeline (visibility + permission). `user` is
    # the creator, so this isolates these specs to the dependents behaviour.
    allow_any_instance_of(User).to receive(:has_permission?).and_return(true)
  end

  after { Current.reset }

  def json_response
    JSON.parse(response.body)
  end

  def build_form(destination)
    CrmForm.create!(
      name: "Form #{SecureRandom.hex(4)}",
      default_pipeline: destination,
      default_stage: destination.pipeline_stages.first,
      published: true,
      fields: [
        { 'key' => 'full_name', 'label' => 'Name', 'type' => 'text', 'required' => true, 'maps_to' => 'name' },
        { 'key' => 'email', 'label' => 'Email', 'type' => 'email', 'required' => true, 'maps_to' => 'email' }
      ]
    )
  end

  it 'returns an empty list when nothing depends on the pipeline' do
    get "/api/v1/pipelines/#{pipeline.id}/dependents", as: :json

    expect(response).to have_http_status(:ok)
    expect(json_response['data']['crm_forms']).to eq([])
  end

  it 'lists the capture forms whose destination is this pipeline' do
    form = build_form(pipeline)

    get "/api/v1/pipelines/#{pipeline.id}/dependents", as: :json

    expect(response).to have_http_status(:ok)
    listed = json_response['data']['crm_forms']
    expect(listed.map { |f| f['id'] }).to eq([form.id])
    expect(listed.first['published']).to be(true)
  end

  # A routing rule overrides the form's default destination, so matching only the default
  # would report "nothing depends on this" while rule-routed leads keep arriving.
  it 'lists a form that reaches this pipeline through a routing rule' do
    other = Pipeline.create!(name: "Other #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user)
    other.pipeline_stages.create!(name: 'New', position: 1)
    form = build_form(other)
    form.update!(routing_rules: [{ 'field' => 'plan', 'op' => 'equals', 'value' => 'gold', 'pipeline_id' => pipeline.id }])

    get "/api/v1/pipelines/#{pipeline.id}/dependents", as: :json

    listed = json_response['data']['crm_forms']
    expect(listed.map { |f| f['id'] }).to eq([form.id])
    expect(listed.first['via']).to eq('routing_rule')
  end

  it 'counts only published forms separately from the full list' do
    build_form(pipeline)
    build_form(pipeline).update!(published: false)

    get "/api/v1/pipelines/#{pipeline.id}/dependents", as: :json

    expect(json_response['data']['count']).to eq(2)
    expect(json_response['data']['published_count']).to eq(1)
  end

  it 'withholds form names from a caller without crm_forms.read' do
    build_form(pipeline)
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?) do |_, _, key|
      key != 'crm_forms.read'
    end

    get "/api/v1/pipelines/#{pipeline.id}/dependents", as: :json

    expect(response).to have_http_status(:ok)
    expect(json_response['data']['count']).to eq(1)
    expect(json_response['data']['crm_forms']).to eq([])
    expect(json_response['data']['names_redacted']).to be(true)
  end

  it 'does not list forms pointing at a different pipeline' do
    other = Pipeline.create!(name: "Other #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user)
    other.pipeline_stages.create!(name: 'New', position: 1)
    build_form(other)

    get "/api/v1/pipelines/#{pipeline.id}/dependents", as: :json

    expect(json_response['data']['crm_forms']).to eq([])
  end

  # The dialog must not imply it checked automations or journeys — those are separate cards.
  it 'declares which dependency kinds were inspected' do
    get "/api/v1/pipelines/#{pipeline.id}/dependents", as: :json

    expect(json_response['data']['inspected']).to eq(['crm_forms'])
  end
end
