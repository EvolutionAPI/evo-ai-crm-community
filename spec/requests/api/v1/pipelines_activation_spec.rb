# frozen_string_literal: true

require 'rails_helper'

# EVO-2122: PATCH /pipelines/:id answered 200 with success: true while dropping
# is_active in strong params, so deactivation was a silent no-op. These specs
# cover the round trip (deactivate, reactivate), the false-success guard, and
# the opt-in listing that keeps a deactivated pipeline reachable for reactivation.
RSpec.describe 'Pipeline activation', type: :request do
  let(:user) { User.create!(name: 'Pipeline Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let!(:pipeline) do
    Pipeline.create!(name: "Sales #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user)
  end

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?).and_return(true)
    # EVO-2204: the direct-ID actions now authorize the pipeline, which re-checks the
    # permission through the model seam. The owner holds it; visibility passes since
    # `user` is the creator — this isolates these specs to the activation behaviour.
    allow_any_instance_of(User).to receive(:has_permission?).and_return(true)
  end

  after { Current.reset }

  def json_response
    JSON.parse(response.body)
  end

  it 'starts active so the deactivation specs below assert a real transition' do
    expect(pipeline.is_active).to be(true)
  end

  describe 'PATCH /api/v1/pipelines/:id' do
    it 'persists is_active = false (AC1)' do
      patch "/api/v1/pipelines/#{pipeline.id}", params: { pipeline: { is_active: false } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(pipeline.reload.is_active).to be(false)
    end

    it 'reactivates a deactivated pipeline (AC3)' do
      pipeline.update!(is_active: false)

      patch "/api/v1/pipelines/#{pipeline.id}", params: { pipeline: { is_active: true } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(pipeline.reload.is_active).to be(true)
    end

    # The client that reported this bug PATCHes the bare attribute — `{ is_active: false }`
    # with no `pipeline` envelope (pipelinesService.togglePipelineStatus). That body only
    # reaches strong params through ActionController::ParamsWrapper, so the envelope-less
    # payload has to be covered too: wrapping this controller off (as journeys_controller
    # already does) would break the endpoint while every wrapped example stayed green.
    it 'persists is_active sent without the pipeline envelope (AC1)' do
      patch "/api/v1/pipelines/#{pipeline.id}", params: { is_active: false }, as: :json

      expect(response).to have_http_status(:ok)
      expect(pipeline.reload.is_active).to be(false)
    end

    it 'reactivates from a payload sent without the pipeline envelope (AC3)' do
      pipeline.update!(is_active: false)

      patch "/api/v1/pipelines/#{pipeline.id}", params: { is_active: true }, as: :json

      expect(response).to have_http_status(:ok)
      expect(pipeline.reload.is_active).to be(true)
    end

    it 'reports the new state in the serialized payload (AC2)' do
      patch "/api/v1/pipelines/#{pipeline.id}", params: { pipeline: { is_active: false } }, as: :json

      expect(json_response['data']['is_active']).to be(false)
    end

    it 'rejects a payload with no permitted attributes instead of reporting success (AC4)' do
      patch "/api/v1/pipelines/#{pipeline.id}",
            params: { pipeline: { created_at: 1.day.ago } }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response['error']['code']).to eq('INVALID_PARAMETER')
    end

    it 'still updates the previously permitted attributes' do
      patch "/api/v1/pipelines/#{pipeline.id}", params: { pipeline: { name: 'Renamed' } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(pipeline.reload.name).to eq('Renamed')
    end

    it 'keeps deactivation behind pipelines.write' do
      allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?).and_return(false)

      patch "/api/v1/pipelines/#{pipeline.id}", params: { pipeline: { is_active: false } }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(pipeline.reload.is_active).to be(true)
    end
  end

  describe 'POST /api/v1/pipelines' do
    before { allow_any_instance_of(PipelinePolicy).to receive(:create?).and_return(true) }

    it 'ignores is_active on creation so a pipeline is always born active' do
      post '/api/v1/pipelines',
           params: { pipeline: { name: "New #{SecureRandom.hex(3)}", pipeline_type: 'sales', is_active: false } },
           as: :json

      expect(response).to have_http_status(:created).or have_http_status(:ok)
      expect(Pipeline.find(json_response['data']['id']).is_active).to be(true)
    end
  end

  describe 'PATCH /api/v1/pipelines/:id/archive' do
    it 'still deactivates through the legacy route' do
      patch "/api/v1/pipelines/#{pipeline.id}/archive", as: :json

      expect(response).to have_http_status(:ok)
      expect(pipeline.reload.is_active).to be(false)
    end
  end

  describe 'GET /api/v1/pipelines' do
    before { pipeline.update!(is_active: false) }

    it 'hides inactive pipelines by default so pickers stay unaffected' do
      get '/api/v1/pipelines', as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data'].map { |p| p['id'] }).not_to include(pipeline.id)
    end

    it 'keeps hiding them when the caller opts out explicitly' do
      get '/api/v1/pipelines?include_inactive=false', as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data'].map { |p| p['id'] }).not_to include(pipeline.id)
    end

    it 'includes inactive pipelines when the caller opts in (AC2, AC3)' do
      get '/api/v1/pipelines?include_inactive=true', as: :json

      expect(response).to have_http_status(:ok)
      listed = json_response['data'].find { |p| p['id'] == pipeline.id }
      expect(listed).to be_present
      expect(listed['is_active']).to be(false)
    end
  end
end
