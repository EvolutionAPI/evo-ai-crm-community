# frozen_string_literal: true

require 'rails_helper'
require 'zip'
require 'stringio'

# CRM-206 — the export enumerated EVERY pipeline, ignoring `visibility`. Each of
# its three enumeration paths (inventory, `all`, explicit id) is covered in its own
# example, because a fix that lands in one and misses another still leaks.
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
      ids = response.parsed_body.dig('data', 'pipelines').map { |p| p['id'] }
      expect(ids).to include(own_private.id, public_pipeline.id)
      expect(ids).not_to include(foreign_private.id)
    end

    # The branch that separates pipelines from macros: access comes from TEAM
    # MEMBERSHIP, not ownership, so a fix leaning on the macro shape fails only
    # here. The outsider is a THIRD user because other_user owns the funnel.
    it 'includes a team-visible funnel for a member, and hides it from a non-member' do
      outsider = User.create!(name: 'Outsider', email: "out-#{SecureRandom.hex(4)}@example.com")
      TeamMember.create!(team: team, user: exporter)
      PipelineTeam.create!(pipeline: team_pipeline, team: team)

      login_as(exporter, 'templates.export')
      get '/api/v1/templates/exportable_inventory', as: :json
      member_ids = response.parsed_body.dig('data', 'pipelines').map { |p| p['id'] }

      Current.reset
      login_as(outsider, 'templates.export')
      get '/api/v1/templates/exportable_inventory', as: :json
      outsider_ids = response.parsed_body.dig('data', 'pipelines').map { |p| p['id'] }

      expect(member_ids).to include(team_pipeline.id)
      expect(outsider_ids).not_to include(team_pipeline.id)
    end

    # An inherited consequence, not a decision of this card: accessible_by ORs in
    # `is_default`, so a private-AND-default funnel is readable — and exportable —
    # by everyone. If that is wrong it is wrong for the pipeline LIST too, and the
    # fix belongs in accessible_by, not in a stricter rule invented here.
    it 'exposes a private-but-default funnel to everyone, exactly as accessible_by does' do
      default_private = Pipeline.create!(name: 'Default funnel', visibility: :private,
                                         created_by: other_user, is_default: true)
      login_as(exporter, 'templates.export')

      get '/api/v1/templates/exportable_inventory', as: :json

      ids = response.parsed_body.dig('data', 'pipelines').map { |p| p['id'] }
      expect(ids).to include(default_private.id)
      expect(Pipeline.accessible_by(exporter).pluck(:id)).to include(default_private.id)
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

    # Catches the opposite error: over-scoping would silently drop account-wide
    # assets from every bundle, and no test of the leak itself would notice.
    it 'leaves account-wide categories (labels) fully exportable' do
      login_as(exporter, 'templates.export')
      Label.create!(title: "shared-#{SecureRandom.hex(3)}")

      post '/api/v1/templates/export',
           params: { template_name: 'T', selection: { labels: { all: true } } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(category_in_bundle(response.body, 'labels').length).to eq(Label.count)
    end

    it 'still exports every agent — agents have no per-user visibility' do
      login_as(exporter, 'templates.export')
      # The test DB has no bots of its own, so without this the count guard would
      # compare 0 to 0 and pass against an empty relation too.
      AgentBot.create!(name: "bot-#{SecureRandom.hex(3)}")

      post '/api/v1/templates/export',
           params: { template_name: 'T', selection: { agents: { all: true } } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(category_in_bundle(response.body, 'agents').length).to eq(AgentBot.count)
    end
  end

  # --- the userless caller: the export delegates, it does not decide -----------

  # The CRM-205 review's High finding was the export answering this for itself. The
  # answer belongs to the category's rule, and the two userless callers differ.
  describe 'userless callers follow the pipeline rule' do
    it 'lists public + default only for a bare userless caller — no private, no raise' do
      Current.reset

      names = Templates::ExportService.exportable_inventory(current_user: nil)['pipelines'].pluck(:name)

      # Private pipelines exist in the DB; a bare caller sees none of them.
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
    # Asserting what the router RETURNS, never a list of category names: a constant
    # nothing reads stays green while `for` quietly gains or loses a branch.
    it 'hands every account-wide category its untouched relation' do
      %w[labels teams inboxes agents canned_responses message_templates custom_attributes].each do |category|
        model = Templates::BundleBuilder::MODEL_MAP[category]
        expect(Templates::VisibilityScope.for(category, model, exporter).to_sql).to eq(model.all.to_sql)
      end
    end

    it 'scopes the two categories that carry per-user visibility' do
      expect(Templates::VisibilityScope.for('pipelines', Pipeline, exporter).to_sql).not_to eq(Pipeline.all.to_sql)
      expect(Templates::VisibilityScope.for('macros', Macro, exporter).to_sql).not_to eq(Macro.all.to_sql)
    end

    it 'delegates pipelines to the same rule the rest of the CRM reads through' do
      expect(Templates::VisibilityScope.for('pipelines', Pipeline, exporter).pluck(:id))
        .to match_array(Pipeline.accessible_by(exporter).pluck(:id))
    end
  end
end
