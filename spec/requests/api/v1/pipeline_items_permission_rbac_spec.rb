# frozen_string_literal: true

require 'rails_helper'
require 'yaml'

# Permission-level proof for the pipeline card-write gate (card #178).
# PipelineItemsController authorizes its WRITE_ACTIONS via PipelinePolicy#update_items?,
# which requires the dedicated `pipeline_items.update` permission — NOT the
# manager-level `pipelines.update`. This guards against a future edit silently
# re-coupling card writes to pipelines.update (the over-grant that let an agent
# archive the funnel) or dropping the key from the catalog.
RSpec.describe 'Pipeline card-write permission (pipeline_items.update)', type: :request do
  let(:user) { User.create!(name: 'Perm Probe', email: "probe-#{SecureRandom.hex(4)}@example.com") }
  # Public pipeline so accessible_record? passes for any user — isolates the
  # permission check from the visibility check.
  let(:pipeline) do
    Pipeline.create!(name: 'Sales', pipeline_type: 'sales', visibility: :public, created_by: user)
  end

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
  end

  after { Current.reset }

  # Stubs the permission seam (User#has_permission? -> PermissionResolver ->
  # EvoAuthService#check_user_permission) to a literal allow-list.
  def grant_permissions(*granted)
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_svc, _uid, permission|
      granted.include?(permission)
    end
  end

  def create_card
    post "/api/v1/pipelines/#{pipeline.id}/pipeline_items",
         params: { pipeline_item: { entity_type: 'lead' } }, as: :json
  end

  it 'DENIES a card write to a user without pipeline_items.update' do
    grant_permissions('pipelines.read')

    expect { create_card }.not_to change(PipelineItem, :count)
    expect(response).to have_http_status(:unauthorized)
  end

  it 'DENIES a card write to a holder of pipelines.update but NOT pipeline_items.update (the split is real)' do
    # Before card #178, granting pipelines.update was the only way to unblock the
    # card — but it also unlocked archive/set_as_default. It must NOT imply card writes.
    grant_permissions('pipelines.read', 'pipelines.update')

    expect { create_card }.not_to change(PipelineItem, :count)
    expect(response).to have_http_status(:unauthorized)
  end

  it 'AUTHORIZES a card write for a holder of pipeline_items.update' do
    grant_permissions('pipelines.read', 'pipeline_items.update')

    create_card

    # The authorization gate opened (no Pundit 401); card-body validation is out of
    # scope for this authz spec.
    expect(response).not_to have_http_status(:unauthorized)
  end

  it 'gates on a permission key that exists in the auth catalog mirror' do
    catalog = YAML.safe_load_file(Rails.root.join('spec/fixtures/rbac/permission_catalog.yml')).to_set
    expect(catalog).to include('pipeline_items.update')
  end
end
