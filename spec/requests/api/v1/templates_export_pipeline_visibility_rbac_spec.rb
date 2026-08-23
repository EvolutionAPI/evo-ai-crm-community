# frozen_string_literal: true

require 'rails_helper'
require 'zip'
require 'stringio'

# CRM-206 — the template export enumerated EVERY pipeline, ignoring the
# `visibility` enum (private/team/public). A templates.export holder read the name
# of another user's private funnel in the inventory, and could then export its
# serialized contents by id. Same class of hole CRM-205 closed for macros, one
# layer over.
#
# Every pipeline enumeration in the export path — inventory, `all`, explicit id —
# now goes through Templates::VisibilityScope, which routes to the rule that
# already governs pipeline reads (PipelinePolicy::Scope / Pipeline.accessible_by),
# including its answer for a userless caller. The export must not second-guess it.
RSpec.describe 'Template export pipeline visibility scope (CRM-206)', type: :request do
  let(:exporter) { User.create!(name: 'Exporter', email: "exp-#{SecureRandom.hex(4)}@example.com") }
  let(:other_user) { User.create!(name: 'Other', email: "other-#{SecureRandom.hex(4)}@example.com") }

  let!(:own_private) do
    Pipeline.create!(name: 'Exporter private funnel', visibility: :private, created_by: exporter)
  end
  let!(:public_pipeline) do
    Pipeline.create!(name: 'Shared public funnel', visibility: :public, created_by: other_user)
  end
  let!(:foreign_private) do
    Pipeline.create!(name: 'Foreign private funnel', visibility: :private, created_by: other_user)
  end

  # `team` visibility is the branch that distinguishes pipelines from macros: it
  # grants access through TEAM MEMBERSHIP, not ownership. A scope that only checked
  # `created_by` would wrongly hide this one from a member.
  let!(:team) { Team.create!(name: "Squad #{SecureRandom.hex(3)}") }
  let!(:team_pipeline) do
    Pipeline.create!(name: 'Team funnel', visibility: :team, created_by: other_user)
  end

  def login_as(user, *granted)
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = user
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_svc, _uid, permission|
      granted.include?(permission)
    end
  end

  after { Current.reset }

  def category_in_bundle(zip_binary, category)
    Zip::InputStream.open(StringIO.new(zip_binary)) do |io|
      while (entry = io.get_next_entry)
        return JSON.parse(io.read) if entry.name == "#{category}.json"
      end
    end
    []
  end

  def pipelines_in_bundle(zip_binary)
    category_in_bundle(zip_binary, 'pipelines')
  end

  # --- path 1: the inventory the wizard renders -------------------------------

  describe 'GET /api/v1/templates/exportable_inventory' do
    it "lists the caller's own + public, never another user's private funnel" do
      login_as(exporter, 'templates.export')

      get '/api/v1/templates/exportable_inventory', as: :json

      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body).dig('data', 'pipelines').map { |p| p['id'] }
      expect(ids).to include(own_private.id, public_pipeline.id)
      expect(ids).not_to include(foreign_private.id)
    end

    # The branch that separates pipelines from macros: access here comes from TEAM
    # MEMBERSHIP, not ownership. A scope that only checked `created_by` would hide
    # this funnel from a member who is entitled to it — a fix that leans on the
    # macro shape would pass every other example in this file and fail only here.
    #
    # The outsider is a THIRD user on purpose: other_user created the funnel, so
    # they see it by ownership and would prove nothing about membership.
    it 'includes a team-visible funnel for a member, and hides it from a non-member' do
      outsider = User.create!(name: 'Outsider', email: "out-#{SecureRandom.hex(4)}@example.com")
      TeamMember.create!(team: team, user: exporter)
      PipelineTeam.create!(pipeline: team_pipeline, team: team)

      login_as(exporter, 'templates.export')
      get '/api/v1/templates/exportable_inventory', as: :json
      member_ids = JSON.parse(response.body).dig('data', 'pipelines').map { |p| p['id'] }

      Current.reset
      login_as(outsider, 'templates.export')
      get '/api/v1/templates/exportable_inventory', as: :json
      outsider_ids = JSON.parse(response.body).dig('data', 'pipelines').map { |p| p['id'] }

      expect(member_ids).to include(team_pipeline.id)
      expect(outsider_ids).not_to include(team_pipeline.id)
    end

    # Pinning an inherited consequence rather than a decision of this card.
    #
    # Pipeline.accessible_by ORs in `where(is_default: true)`, so a pipeline that
    # is BOTH private and default is readable by everyone — and therefore
    # exportable by everyone. That is the rule the whole CRM already reads
    # through, and the export deliberately inherits it instead of inventing a
    # stricter one here.
    #
    # If it is ever judged wrong, it is wrong for the pipeline LIST too, and the
    # fix belongs in accessible_by. Documented so the next reader does not mistake
    # it for a gap in the export.
    it 'exposes a private-but-default funnel to everyone, exactly as accessible_by does' do
      default_private = Pipeline.create!(name: 'Default funnel', visibility: :private,
                                         created_by: other_user, is_default: true)
      login_as(exporter, 'templates.export')

      get '/api/v1/templates/exportable_inventory', as: :json

      ids = JSON.parse(response.body).dig('data', 'pipelines').map { |p| p['id'] }
      expect(ids).to include(default_private.id)
      expect(::Pipeline.accessible_by(exporter).pluck(:id)).to include(default_private.id)
    end
  end

  describe 'POST /api/v1/templates/export' do
    # --- path 2: selection `all` ---------------------------------------------

    it "with `all`, the bundle carries the caller's own + public, not another user's private" do
      login_as(exporter, 'templates.export')

      post '/api/v1/templates/export',
           params: { template_name: 'T', selection: { pipelines: { all: true } } }, as: :json

      expect(response).to have_http_status(:ok)
      names = pipelines_in_bundle(response.body).map { |p| p['name'] }
      expect(names).to include('Exporter private funnel', 'Shared public funnel')
      expect(names).not_to include('Foreign private funnel')
    end

    # --- path 3: an explicit id, crafted from a leaked UUID --------------------

    it "ignores an explicit id crafted from another user's private funnel (defense in depth)" do
      login_as(exporter, 'templates.export')

      post '/api/v1/templates/export',
           params: { template_name: 'T',
                     selection: { pipelines: { ids: [foreign_private.id, own_private.id] } } },
           as: :json

      expect(response).to have_http_status(:ok)
      names = pipelines_in_bundle(response.body).map { |p| p['name'] }
      expect(names).to include('Exporter private funnel')
      expect(names).not_to include('Foreign private funnel')
    end

    it 'denies the whole export without templates.export' do
      login_as(exporter) # no keys

      post '/api/v1/templates/export',
           params: { template_name: 'T', selection: { pipelines: { all: true } } }, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    # --- the over-scoping guard ----------------------------------------------

    # The fix must touch pipelines (and macros) ONLY. Labels and the other
    # account-wide categories are shared, so `all` must still export every one of
    # them — a base_relation that scoped them too would silently drop account-wide
    # assets from every bundle, and no test of the leak itself would notice.
    it 'leaves account-wide categories (labels) fully exportable' do
      login_as(exporter, 'templates.export')
      Label.create!(title: "shared-#{SecureRandom.hex(3)}")

      post '/api/v1/templates/export',
           params: { template_name: 'T', selection: { labels: { all: true } } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(category_in_bundle(response.body, 'labels').length).to eq(1)
    end

    it 'still exports every agent — agents have no per-user visibility' do
      login_as(exporter, 'templates.export')

      post '/api/v1/templates/export',
           params: { template_name: 'T', selection: { agents: { all: true } } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(category_in_bundle(response.body, 'agents').length).to eq(AgentBot.count)
    end
  end

  # --- the userless caller: the export delegates, it does not decide -----------

  # This is the shape of the High finding from the CRM-205 review: the export tried
  # to answer for a userless caller on its own. The answer belongs to the rule that
  # governs the category, and the two callers differ.
  describe 'userless callers follow the pipeline rule' do
    it 'lists public + default only for a bare userless caller — no private, no raise' do
      Current.reset
      expect(foreign_private).to be_present # private pipelines exist in the DB…

      names = Templates::ExportService.exportable_inventory(current_user: nil)['pipelines'].pluck(:name)

      # …but a bare caller sees none of them.
      expect(names).to include('Shared public funnel')
      expect(names).not_to include('Foreign private funnel', 'Exporter private funnel')
    end

    it 'lists every pipeline for a service token, matching PipelinePolicy::Scope' do
      Current.reset
      Current.service_authenticated = true

      names = Templates::ExportService.exportable_inventory(current_user: nil)['pipelines'].pluck(:name)

      expect(names).to match_array(Pipeline.pluck(:name))
      expect(names).to include('Foreign private funnel')
    end
  end

  # --- the router itself -------------------------------------------------------

  describe 'Templates::VisibilityScope' do
    it 'routes only the categories that have per-user visibility' do
      expect(Templates::VisibilityScope.scoped?('pipelines')).to be(true)
      expect(Templates::VisibilityScope.scoped?('macros')).to be(true)
      %w[labels teams inboxes agents canned_responses message_templates custom_attributes].each do |category|
        expect(Templates::VisibilityScope.scoped?(category)).to be(false)
      end
    end

    it 'hands an account-wide category its untouched relation' do
      relation = Templates::VisibilityScope.for('labels', ::Label, exporter)
      expect(relation.to_sql).to eq(::Label.all.to_sql)
    end

    it 'delegates pipelines to the same rule the rest of the CRM reads through' do
      expect(Templates::VisibilityScope.for('pipelines', ::Pipeline, exporter).pluck(:id))
        .to match_array(::Pipeline.accessible_by(exporter).pluck(:id))
    end
  end
end
