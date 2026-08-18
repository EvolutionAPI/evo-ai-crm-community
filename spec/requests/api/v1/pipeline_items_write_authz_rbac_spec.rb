# frozen_string_literal: true

require 'rails_helper'

# Pipeline item mutating actions authorize against the dedicated CARD-write policy
# (PipelinePolicy#update_items? -> pipeline_items.update), while reads stay at
# #view?. These specs prove the split: a caller allowed to VIEW the pipeline but
# lacking card-write can list items but cannot create one. (The permission-level
# proof — that pipeline_items.update, not pipelines.update, is what gates card
# writes — lives in pipeline_items_permission_rbac_spec.rb.)
RSpec.describe 'Pipeline item write-level authorization', type: :request do
  let(:user) { User.create!(name: 'Perm Probe', email: "probe-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: 'Sales', pipeline_type: 'sales', created_by: user) }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    # View is permitted, card-write is not: isolates the read-vs-card-write level.
    allow_any_instance_of(PipelinePolicy).to receive(:view?).and_return(true)
    allow_any_instance_of(PipelinePolicy).to receive(:update_items?).and_return(false)
  end

  after { Current.reset }

  it 'allows listing items with only view-level access' do
    get "/api/v1/pipelines/#{pipeline.id}/pipeline_items", as: :json

    expect(response).to have_http_status(:ok)
  end

  it 'denies creating an item without write-level access' do
    expect do
      post "/api/v1/pipelines/#{pipeline.id}/pipeline_items",
           params: { pipeline_item: { entity_type: 'lead' } }, as: :json
    end.not_to change(PipelineItem, :count)

    expect(response).to have_http_status(:unauthorized)
  end
end
