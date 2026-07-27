# frozen_string_literal: true

require 'rails_helper'

# EVO-2204: PipelinePolicy was permission-only, so the visibility model
# (private / public / team, plus is_default and creator) was enforced only in
# #index. Every direct-ID action resolved the pipeline with a bare find and never
# consulted visibility, letting any user holding pipelines.* reach another user's
# private pipeline (horizontal privilege escalation).
#
# These specs pin the fix: the record-level policy rules (and the child
# controllers that authorize through them) now AND the permission with the same
# Scope#resolve that filters the list, so detail and list can never disagree.
# Permissions are stubbed true throughout to isolate the visibility dimension.
RSpec.describe 'Pipeline visibility authorization', type: :request do
  let(:owner) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:other) { User.create!(name: 'Other', email: "other-#{SecureRandom.hex(4)}@example.com") }

  let(:private_pipeline) do
    Pipeline.create!(name: "Private #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: owner)
  end

  before do
    spec = self
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = spec.acting_user
      Current.evo_role_key = spec.acting_role
      Current.evo_permission_cache ||= {}
    end
    # Both users hold every pipelines.* permission: the only variable under test is visibility.
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?).and_return(true)
    allow_any_instance_of(User).to receive(:has_permission?).and_return(true)
  end

  after { Current.reset }

  attr_accessor :acting_user, :acting_role

  def act_as(user, role: nil)
    self.acting_user = user
    self.acting_role = role
  end

  describe 'a private pipeline' do
    context 'when the requester is the creator' do
      before { act_as(owner) }

      it 'allows show' do
        get "/api/v1/pipelines/#{private_pipeline.id}", as: :json
        expect(response).to have_http_status(:ok)
      end

      it 'allows stats' do
        get "/api/v1/pipelines/#{private_pipeline.id}/stats", as: :json
        expect(response).to have_http_status(:ok)
      end

      it 'allows update' do
        patch "/api/v1/pipelines/#{private_pipeline.id}", params: { pipeline: { name: 'Renamed' } }, as: :json
        expect(response).to have_http_status(:ok)
      end

      it 'allows archive' do
        patch "/api/v1/pipelines/#{private_pipeline.id}/archive", as: :json
        expect(response).to have_http_status(:ok)
      end

      it 'allows set_as_default' do
        patch "/api/v1/pipelines/#{private_pipeline.id}/set_as_default", as: :json
        expect(response).to have_http_status(:ok)
      end

      it 'allows destroy' do
        delete "/api/v1/pipelines/#{private_pipeline.id}", as: :json
        expect(response).to have_http_status(:ok)
      end

      it 'allows dependents' do
        get "/api/v1/pipelines/#{private_pipeline.id}/dependents", as: :json
        expect(response).to have_http_status(:ok)
      end
    end

    context 'when the requester is not the creator (AC1, AC2)' do
      before { act_as(other) }

      it 'denies show' do
        get "/api/v1/pipelines/#{private_pipeline.id}", as: :json
        expect(response).to have_http_status(:unauthorized)
      end

      it 'denies stats' do
        get "/api/v1/pipelines/#{private_pipeline.id}/stats", as: :json
        expect(response).to have_http_status(:unauthorized)
      end

      it 'denies update and does not mutate' do
        patch "/api/v1/pipelines/#{private_pipeline.id}", params: { pipeline: { name: 'Hijacked' } }, as: :json
        expect(response).to have_http_status(:unauthorized)
        expect(private_pipeline.reload.name).not_to eq('Hijacked')
      end

      it 'denies archive and does not deactivate' do
        patch "/api/v1/pipelines/#{private_pipeline.id}/archive", as: :json
        expect(response).to have_http_status(:unauthorized)
        expect(private_pipeline.reload.is_active).to be(true)
      end

      it 'denies set_as_default and does not promote' do
        patch "/api/v1/pipelines/#{private_pipeline.id}/set_as_default", as: :json
        expect(response).to have_http_status(:unauthorized)
        expect(private_pipeline.reload.is_default).to be(false)
      end

      it 'denies destroy and does not delete' do
        pipeline = private_pipeline
        delete "/api/v1/pipelines/#{pipeline.id}", as: :json
        expect(response).to have_http_status(:unauthorized)
        expect(Pipeline.exists?(pipeline.id)).to be(true)
      end

      it 'denies dependents (EVO-2204: same bare-id path)' do
        get "/api/v1/pipelines/#{private_pipeline.id}/dependents", as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    # The visibility model is role-agnostic (accessible_by has no admin bypass):
    # an administrator/super_admin is NOT exempt from it. Pinning this guards
    # against a bypass being reintroduced by accident; whether admins SHOULD see
    # everything is a deliberate product decision tracked separately (EVO-2222).
    context 'when the requester is an administrator but not the creator' do
      before { act_as(other, role: 'super_admin') }

      it 'still denies show' do
        get "/api/v1/pipelines/#{private_pipeline.id}", as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'a non-creator reading a shared pipeline' do
    before { act_as(other) }

    it 'is allowed when the pipeline is public' do
      public_pipeline = Pipeline.create!(
        name: "Public #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: owner, visibility: :public
      )

      get "/api/v1/pipelines/#{public_pipeline.id}", as: :json
      expect(response).to have_http_status(:ok)
    end

    it 'is allowed when the pipeline is the account default' do
      default_pipeline = Pipeline.create!(
        name: "Default #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: owner, is_default: true
      )

      get "/api/v1/pipelines/#{default_pipeline.id}", as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  # EVO-2222 shipped `team` visibility inside accessible_by; because the record
  # check routes through the same scope, a team member reaches a team-visible
  # pipeline while a non-member does not — detail stays consistent with the list.
  describe 'a team-visible pipeline' do
    let(:team) { Team.create!(name: "Team #{SecureRandom.hex(3)}") }
    let(:team_pipeline) do
      pipeline = Pipeline.create!(
        name: "Team #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: owner, visibility: :team
      )
      PipelineTeam.create!(pipeline: pipeline, team: team)
      pipeline
    end

    it 'allows a member of the shared team' do
      TeamMember.create!(team: team, user: other)
      act_as(other)

      get "/api/v1/pipelines/#{team_pipeline.id}", as: :json
      expect(response).to have_http_status(:ok)
    end

    it 'denies a user outside the shared team' do
      act_as(other)

      get "/api/v1/pipelines/#{team_pipeline.id}", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # AC4: child controllers authorize @pipeline, :view? — a read-level alias of the
  # now visibility-aware show?. Proving one (pipeline_stages) proves the inheritance.
  describe 'child controller inheritance (AC4)' do
    it 'denies a non-creator listing stages of a private pipeline' do
      act_as(other)

      get "/api/v1/pipelines/#{private_pipeline.id}/pipeline_stages", as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'allows the creator to list stages' do
      act_as(owner)

      get "/api/v1/pipelines/#{private_pipeline.id}/pipeline_stages", as: :json
      expect(response).to have_http_status(:ok)
    end
  end
end
